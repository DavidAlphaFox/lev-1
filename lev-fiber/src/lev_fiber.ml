open Stdune
open Fiber.O
open Util
module Timestamp = Lev.Timestamp

type t = {
  loop : Lev.Loop.t;
  queue : Fiber.fill Queue.t;
  (* TODO stop when there are no threads *)
  async : Lev.Async.t;
  thread_jobs : Fiber.fill Queue.t;
  thread_mutex : Mutex.t;
}

type scheduler = t

let t : t Fiber.Var.t = Fiber.Var.create ()
let scheduler = t

module Buffer = struct
  include Bip_buffer

  let default_size = 4096

  type t = Bytes.t Bip_buffer.t

  let create ~size : t = create (Bytes.create size) ~len:size
end

module State = struct
  type 'a t' = Open of 'a | Closed
  type 'a t = 'a t' ref

  let check_open t =
    match !t with Closed -> Code_error.raise "must be opened" [] | Open a -> a

  let create a = ref (Open a)
  let close t = t := Closed
end

module Thread = struct
  type job =
    | Job :
        (unit -> 'a)
        * ('a, [ `Exn of Exn_with_backtrace.t | `Cancelled ]) result
          Fiber.Ivar.t
        -> job

  type t = { worker : job Worker.t }

  let spawn_thread f =
    let (_ : Thread.t) = Thread.create f () in
    ()

  let create () =
    let+ t = Fiber.Var.get_exn t in
    let do_no_raise (Job (f, ivar)) =
      let res =
        match Exn_with_backtrace.try_with f with
        | Ok x -> Ok x
        | Error exn -> Error (`Exn exn)
      in
      Mutex.lock t.thread_mutex;
      Queue.push t.thread_jobs (Fiber.Fill (ivar, res));
      Mutex.unlock t.thread_mutex;
      Lev.Async.send t.async t.loop
    in
    let worker = Worker.create ~spawn_thread ~do_no_raise in
    { worker }

  type 'a task = {
    ivar :
      ('a, [ `Exn of Exn_with_backtrace.t | `Cancelled ]) result Fiber.Ivar.t;
    task : Worker.task;
  }

  let task t ~f =
    Fiber.of_thunk (fun () ->
        let ivar = Fiber.Ivar.create () in
        let task =
          match Worker.add_work t.worker (Job (f, ivar)) with
          | Ok task -> task
          | Error `Stopped -> Code_error.raise "already stopped" []
        in
        Fiber.return { ivar; task })

  let await task = Fiber.Ivar.read task.ivar

  let cancel task =
    let* status = Fiber.Ivar.peek task.ivar in
    match status with
    | Some _ -> Fiber.return ()
    | None ->
        Worker.cancel_if_not_consumed task.task;
        Fiber.Ivar.fill task.ivar (Error `Cancelled)

  let close t = Worker.complete_tasks_and_stop t.worker
end

module Timer = struct
  let sleepf after =
    let* t = Fiber.Var.get_exn t in
    let ivar = Fiber.Ivar.create () in
    let timer =
      Lev.Timer.create ~after (fun timer ->
          Lev.Timer.stop timer t.loop;
          Lev.Timer.destroy timer;
          Queue.push t.queue (Fiber.Fill (ivar, ())))
    in
    Lev.Timer.start timer t.loop;
    Fiber.Ivar.read ivar

  module Wheel = struct
    type elt = {
      ivar : [ `Ok | `Cancelled ] Fiber.Ivar.t;
      scheduled : Lev.Timestamp.t;
      mutable filled : bool;
      wheel : running;
    }

    and running = {
      queue : elt Removable_queue.t;
      delay : float;
      scheduler : scheduler;
      mutable waiting_filled : bool;
      mutable waiting : unit Fiber.Ivar.t option;
    }

    and state = Stopped | Running of running
    and t = state ref

    let create ~delay =
      let+ scheduler = Fiber.Var.get_exn t in
      ref
        (Running
           {
             queue = Removable_queue.create ();
             delay;
             scheduler;
             waiting_filled = false;
             waiting = None;
           })

    type task = elt Removable_queue.node ref

    let task (t : t) : task Fiber.t =
      match !t with
      | Stopped -> Code_error.raise "Wheel.task" []
      | Running t ->
          let now = Lev.Loop.now t.scheduler.loop in
          let data =
            {
              wheel = t;
              ivar = Fiber.Ivar.create ();
              scheduled = now;
              filled = false;
            }
          in
          let res = Removable_queue.push t.queue data in
          let+ () =
            match t.waiting with
            | None -> Fiber.return ()
            | Some ivar ->
                if t.waiting_filled then Fiber.return ()
                else (
                  t.waiting_filled <- true;
                  Fiber.Ivar.fill ivar ())
          in
          ref res

    let reset (task : task) =
      let task' = Removable_queue.data !task in
      if not task'.filled then (
        Removable_queue.remove !task;
        let now = Lev.Loop.now task'.wheel.scheduler.loop in
        let task' = { task' with scheduled = now } in
        let new_task = Removable_queue.push task'.wheel.queue task' in
        task := new_task)

    let await (task : task) =
      let task = Removable_queue.data !task in
      Fiber.Ivar.read task.ivar

    let cancel (node : task) =
      let task = Removable_queue.data !node in
      if task.filled then Fiber.return ()
      else (
        task.filled <- true;
        Removable_queue.remove !node;
        Fiber.Ivar.fill task.ivar `Cancelled)

    let rec run t =
      match !t with
      | Stopped -> Fiber.return ()
      | Running r -> (
          match Removable_queue.pop r.queue with
          | None ->
              let ivar = Fiber.Ivar.create () in
              r.waiting <- Some ivar;
              r.waiting_filled <- false;
              let* () = Fiber.Ivar.read ivar in
              r.waiting <- None;
              r.waiting_filled <- false;
              run t
          | Some task ->
              let after =
                let now = Timestamp.to_float (Lev.Loop.now r.scheduler.loop) in
                let scheduled = Timestamp.to_float task.scheduled in
                scheduled -. now +. r.delay
              in
              let scheduler = task.wheel.scheduler in
              let ivar = Fiber.Ivar.create () in
              let timer =
                Lev.Timer.create ~after (fun timer ->
                    (* TODO reuse timer *)
                    Lev.Timer.destroy timer;
                    Queue.push scheduler.queue (Fiber.Fill (ivar, ())))
              in
              Lev.Timer.start timer scheduler.loop;
              let* () = Fiber.Ivar.read ivar in
              let () =
                if not task.filled then (
                  task.filled <- true;
                  Queue.push scheduler.queue (Fiber.Fill (task.ivar, `Ok)))
              in
              run t)

    let stop =
      let rec cancel_all r =
        match Removable_queue.pop r.queue with
        | None -> Fiber.return ()
        | Some task ->
            let* () =
              if task.filled then Fiber.return ()
              else (
                task.filled <- true;
                Fiber.Ivar.fill task.ivar `Cancelled)
            in
            cancel_all r
      in
      fun t ->
        match !t with
        | Stopped -> Fiber.return ()
        | Running r -> (
            t := Stopped;
            let* () = cancel_all r in
            match r.waiting with
            | None -> Fiber.return ()
            | Some w -> Fiber.Ivar.fill w ())
  end
end

let waitpid ~pid =
  let* { loop; queue; _ } = Fiber.Var.get_exn t in
  let ivar = Fiber.Ivar.create () in
  let child =
    Lev.Child.create
      (fun t ~pid:_ process_status ->
        Queue.push queue (Fiber.Fill (ivar, process_status));
        Lev.Child.stop t loop;
        Lev.Child.destroy t)
      (Pid pid) Terminate
  in
  Lev.Child.start child loop;
  Fiber.Ivar.read ivar

module Rc : sig
  type 'a t

  val get : 'a t -> 'a option
  val get_exn : 'a t -> 'a
  val release : _ t -> unit
  val create : count:int -> finalize:(unit -> unit) -> 'a -> 'a t
end = struct
  type 'a state = { data : 'a; mutable count : int; finalize : unit -> unit }
  type 'a t = 'a state State.t

  let get t = match !t with State.Closed -> None | Open a -> Some a.data
  let get_exn t = Option.value_exn (get t)
  let create ~count ~finalize data = State.create { count; finalize; data }

  let _retain t =
    let t = State.check_open t in
    t.count <- t.count + 1

  let release (t : _ t) =
    match !t with
    | Closed -> ()
    | Open a ->
        a.count <- a.count - 1;
        if a.count = 0 then (
          State.close t;
          a.finalize ())
end

module Lev_fd = struct
  type t = {
    io : Lev.Io.t;
    scheduler : scheduler;
    read : unit Fiber.Ivar.t Queue.t;
    write : unit Fiber.Ivar.t Queue.t;
  }

  let fd t = Lev.Io.fd t.io

  let await t (what : Lev.Io.Event.t) =
    let ivar = Fiber.Ivar.create () in
    let q = match what with Write -> t.write | Read -> t.read in
    Queue.push q ivar;
    Fiber.Ivar.read ivar

  let make_finalizer loop io () =
    Lev.Io.stop io loop;
    let fd = Lev.Io.fd io in
    Unix.close fd;
    Lev.Io.destroy io

  let make_cb t scheduler _ _ set =
    match Rc.get (Fdecl.get t) with
    | None -> ()
    | Some nb -> (
        (if Lev.Io.Event.Set.mem set Read then
         match Queue.pop nb.read with
         | Some ivar -> Queue.push scheduler.queue (Fiber.Fill (ivar, ()))
         | None -> ());
        if Lev.Io.Event.Set.mem set Write then
          match Queue.pop nb.write with
          | Some ivar -> Queue.push scheduler.queue (Fiber.Fill (ivar, ()))
          | None -> ())

  let create ~ref_count events fd : t Rc.t Fiber.t =
    let+ scheduler = Fiber.Var.get_exn scheduler in
    let t : t Rc.t Fdecl.t = Fdecl.create Dyn.opaque in
    let io = Lev.Io.create (make_cb t scheduler) fd events in
    Fdecl.set t
      (Rc.create
         ~finalize:(make_finalizer scheduler.loop io)
         ~count:ref_count
         { scheduler; io; read = Queue.create (); write = Queue.create () });
    Lev.Io.start io scheduler.loop;
    Fdecl.get t
end

module Io = struct
  type input = Input
  type output = Output
  type 'a mode = Input : input mode | Output : output mode

  module Slice = Buffer.Slice

  type _ kind =
    | Write : output kind
    | Read : { mutable eof : bool } -> input kind

  module Fd = struct
    type t =
      | Blocking of Thread.t * Unix.file_descr Rc.t
      | Non_blocking of Lev_fd.t Rc.t

    let with_ t (kind : Lev.Io.Event.t) ~f =
      match t with
      | Non_blocking lev_fd ->
          let lev_fd = Rc.get_exn lev_fd in
          let+ () = Lev_fd.await lev_fd kind in
          Result.try_with (fun () -> f (Lev_fd.fd lev_fd))
      | Blocking (th, fd) -> (
          let fd = Rc.get_exn fd in
          let* task = Thread.task th ~f:(fun () -> f fd) in
          let+ res = Thread.await task in
          match res with
          | Ok _ as s -> s
          | Error `Cancelled -> assert false
          | Error (`Exn exn) -> Error exn.exn)

    let release t =
      match t with
      | Non_blocking fd -> Rc.release fd
      | Blocking (th, fd) ->
          Thread.close th;
          Rc.release fd
  end

  type 'a open_ = { mutable buffer : Buffer.t; kind : 'a kind; fd : Fd.t }
  type 'a t = 'a open_ State.t

  let blit ~src ~src_pos ~dst ~dst_pos ~len =
    Bytes.blit ~src ~src_pos ~dst ~dst_pos ~len

  module Writer = struct
    type nonrec t = output open_

    let available t = Buffer.available t.buffer

    let prepare =
      let rec try_ t ~len reserve_fail =
        match Buffer.reserve t.buffer ~len with
        | Some pos ->
            let buf = Buffer.buffer t.buffer in
            (buf, { Slice.pos; len })
        | None -> (
            match reserve_fail with
            | `Compress ->
                if Buffer.unused_space t.buffer >= len then
                  Buffer.compress t.buffer blit;
                try_ t ~len `Resize
            | `Resize ->
                let len = Buffer.length t.buffer + len in
                let new_buf = Bytes.create len in
                let buf = Buffer.resize t.buffer blit new_buf ~len in
                t.buffer <- buf;
                try_ t ~len `Fail
            | `Fail -> assert false)
      in
      fun t ~len -> try_ t ~len `Compress

    let commit t ~len = Buffer.commit t.buffer ~len

    let rec flush (t : t) =
      match Buffer.peek t.buffer with
      | None -> Fiber.return ()
      | Some { Slice.pos; len } -> (
          let buffer = Buffer.buffer t.buffer in
          let* res =
            Fd.with_ t.fd Write ~f:(fun fd ->
                Unix.single_write fd buffer pos len)
          in
          match res with
          | Error (Unix.Unix_error (Unix.EAGAIN, _, _)) -> flush t
          | Error exn -> reraise exn
          | Ok len ->
              Buffer.junk t.buffer ~len;
              flush t)
  end

  let create_gen (type a) fd (mode : a mode) =
    let buffer = Buffer.create ~size:Buffer.default_size in
    let kind : a kind =
      match mode with Input -> Read { eof = false } | Output -> Write
    in
    State.create { buffer; fd; kind }

  let create (type a) fd blockity (mode : a mode) =
    match blockity with
    | `Non_blocking ->
        let+ fd =
          let read, write =
            match mode with Input -> (true, false) | Output -> (false, true)
          in
          let set = Lev.Io.Event.Set.create ~read ~write () in
          Lev_fd.create ~ref_count:1 set fd
        in
        create_gen (Fd.Non_blocking fd) mode
    | `Blocking ->
        let+ thread = Thread.create () in
        let fd = Rc.create ~count:1 ~finalize:(fun () -> Unix.close fd) fd in
        create_gen (Fd.Blocking (thread, fd)) mode

  let create_rw fd blockity : (input t * output t) Fiber.t =
    match blockity with
    | `Non_blocking ->
        let+ fd =
          let set = Lev.Io.Event.Set.create ~read:true ~write:true () in
          let+ fd = Lev_fd.create ~ref_count:2 set fd in
          Fd.Non_blocking fd
        in
        let r = create_gen fd Input in
        let w = create_gen fd Output in
        (r, w)
    | `Blocking ->
        let fd = Rc.create ~count:2 ~finalize:(fun () -> Unix.close fd) fd in
        let* r =
          let+ thread = Thread.create () in
          create_gen (Fd.Blocking (thread, fd)) Input
        in
        let+ w =
          let+ thread = Thread.create () in
          create_gen (Fd.Blocking (thread, fd)) Output
        in
        (r, w)

  let close t =
    match !t with
    | State.Closed -> ()
    | Open o ->
        Fd.release o.fd;
        t := Closed

  module Reader = struct
    type t = input open_

    let buffer t =
      match Buffer.peek t.buffer with
      | None ->
          (* we don't surface empty reads to the user *)
          assert false
      | Some { Buffer.Slice.pos; len } ->
          let b = Buffer.buffer t.buffer in
          (b, { Slice.pos; len })

    let consume (t : t) ~len = Buffer.junk t.buffer ~len

    let available t =
      let eof = match t.kind with Read { eof } -> eof in
      let available = Buffer.length t.buffer in
      if available = 0 && eof then `Eof else `Ok available

    let refill =
      let rec read t ~size ~dst_pos =
        let b = Bytes.create size in
        let* res = Fd.with_ t.fd Read ~f:(fun fd -> Unix.read fd b 0 size) in
        match res with
        | Error (Unix.Unix_error (Unix.EAGAIN, _, _)) -> read t ~size ~dst_pos
        | Ok 0 | Error (Unix.Unix_error (Unix.EBADF, _, _)) ->
            (match t.kind with Read b -> b.eof <- true);
            Buffer.commit t.buffer ~len:0;
            Fiber.return ()
        | Ok len ->
            Bytes.blit ~src:b ~src_pos:0 ~dst:(Buffer.buffer t.buffer) ~dst_pos
              ~len;
            Buffer.commit t.buffer ~len;
            Fiber.return ()
        | Error exn -> reraise exn
      in
      let rec try_ t size reserve_fail =
        match Buffer.reserve t.buffer ~len:size with
        | Some dst_pos -> read t ~size ~dst_pos
        | None -> (
            match reserve_fail with
            | `Compress ->
                if Buffer.unused_space t.buffer >= size then
                  Buffer.compress t.buffer blit;
                try_ t size `Resize
            | `Resize ->
                let len = Buffer.length t.buffer + size in
                let new_buf = Bytes.create len in
                let buf = Buffer.resize t.buffer blit new_buf ~len in
                t.buffer <- buf;
                try_ t size `Fail
            | `Fail -> assert false)
      in
      fun ?(size = Buffer.default_size) t -> try_ t size `Compress
  end

  let with_read (t : input t) ~f =
    let t = State.check_open t in
    f t

  let with_write (t : output t) ~f =
    let t = State.check_open t in
    f t

  let pipe =
    let blockity = if Sys.win32 then `Blocking else `Non_blocking in
    fun ?cloexec () : (input t * output t) Fiber.t ->
      Fiber.of_thunk @@ fun () ->
      let r, w = Unix.pipe ?cloexec () in
      Unix.set_nonblock r;
      Unix.set_nonblock w;
      let* input = create r blockity Input in
      let+ output = create w blockity Output in
      (input, output)
end

module Socket = struct
  let writeable_fd scheduler fd =
    let ivar = Fiber.Ivar.create () in
    let io =
      Lev.Io.create
        (fun io _ _ ->
          Queue.push scheduler.queue (Fiber.Fill (ivar, ()));
          Lev.Io.stop io scheduler.loop;
          Lev.Io.destroy io)
        fd
        (Lev.Io.Event.Set.create ~write:true ())
    in
    Lev.Io.start io scheduler.loop;
    Fiber.Ivar.read ivar

  let connect fd sock =
    let* scheduler = Fiber.Var.get_exn scheduler in
    Unix.set_nonblock fd;
    match Unix.connect fd sock with
    | () -> Fiber.return ()
    | exception Unix.Unix_error (Unix.EISCONN, _, _) -> Fiber.return ()
    | exception Unix.Unix_error (Unix.EINPROGRESS, _, _) -> (
        let+ () = writeable_fd scheduler fd in
        match Unix.getsockopt_error fd with
        | None -> ()
        | Some err -> raise (Unix.Unix_error (err, "connect", "")))

  module Server = struct
    type t = {
      fd : Unix.file_descr;
      pool : Fiber.Pool.t;
      io : Lev.Io.t;
      mutable close : bool;
      mutable await : unit Fiber.Ivar.t;
    }

    let create fd sockaddr ~backlog =
      let+ scheduler = Fiber.Var.get_exn scheduler in
      let pool = Fiber.Pool.create () in
      Unix.set_nonblock fd;
      Unix.bind fd sockaddr;
      Unix.listen fd backlog;
      let t = Fdecl.create Dyn.opaque in
      let io =
        Lev.Io.create
          (fun _ _ _ ->
            let t = Fdecl.get t in
            Queue.push scheduler.queue (Fiber.Fill (t.await, ())))
          fd
          (Lev.Io.Event.Set.create ~read:true ())
      in
      Fdecl.set t { pool; await = Fiber.Ivar.create (); close = false; fd; io };
      Fdecl.get t

    let close t =
      if t.close then Fiber.return ()
      else
        let* scheduler = Fiber.Var.get_exn scheduler in
        Unix.close t.fd;
        Lev.Io.stop t.io scheduler.loop;
        Lev.Io.destroy t.io;
        t.close <- true;
        let* () = Fiber.Pool.stop t.pool in
        Fiber.Ivar.fill t.await ()

    module Session = struct
      type t = { fd : Unix.file_descr; sockaddr : Unix.sockaddr }

      let fd t = t.fd
      let sockaddr t = t.sockaddr

      let io t =
        Unix.set_nonblock t.fd;
        Io.create_rw t.fd `Non_blocking
    end

    let serve =
      let rec loop t f =
        let* () = Fiber.Ivar.read t.await in
        match t.close with
        | true -> Fiber.return ()
        | false ->
            t.await <- Fiber.Ivar.create ();
            let session =
              let fd, sockaddr = Unix.accept ~cloexec:true t.fd in
              { Session.fd; sockaddr }
            in
            let* () = Fiber.Pool.task t.pool ~f:(fun () -> f session) in
            loop t f
      in
      fun (t : t) ~f ->
        let* scheduler = Fiber.Var.get_exn scheduler in
        Lev.Io.start t.io scheduler.loop;
        Fiber.fork_and_join_unit
          (fun () -> Fiber.Pool.run t.pool)
          (fun () -> loop t f)
  end
end

let run lev_loop ~f =
  let thread_jobs = Queue.create () in
  let thread_mutex = Mutex.create () in
  let queue = Queue.create () in
  let async =
    Lev.Async.create (fun _ ->
        Mutex.lock thread_mutex;
        Queue.transfer thread_jobs queue;
        Mutex.unlock thread_mutex)
  in
  Lev.Async.start async lev_loop;
  let f =
    Fiber.Var.set t
      { loop = lev_loop; queue; async; thread_mutex; thread_jobs }
      f
  in
  let rec events q acc =
    match Queue.pop q with None -> acc | Some e -> events q (e :: acc)
  in
  let rec iter_or_deadlock q =
    match Nonempty_list.of_list (events q []) with
    | Some e -> e
    | None -> Code_error.raise "deadlock" []
  and iter loop q =
    match Nonempty_list.of_list (events q []) with
    | Some e -> e
    | None -> (
        let res = Lev.Loop.run loop Once in
        match res with
        | `No_more_active_watchers -> iter_or_deadlock q
        | `Otherwise -> iter loop q)
  in
  Fiber.run f ~iter:(fun () -> iter lev_loop queue)
