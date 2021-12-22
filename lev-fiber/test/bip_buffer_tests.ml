open Stdune
module Bytes = BytesLabels
module B = Util.Bip_buffer

let%expect_test "is_empty" =
  let len = 100 in
  assert (B.is_empty (B.create (Bytes.create len) ~len));
  [%expect {||}]

let%expect_test "read empty" =
  let b = B.create (Bytes.create 0) ~len:1 in
  assert (B.peek b = None);
  [%expect {||}]

let peek_str b ~len =
  match B.peek b with
  | None -> assert false
  | Some s ->
      assert (s.len >= len);
      printfn "Requested %d. Available %d" len s.len;
      let get len =
        let dst = Bytes.create len in
        let src = B.buffer b in
        Bytes.blit ~dst ~dst_pos:0 ~src ~src_pos:s.pos ~len;
        Bytes.to_string dst
      in
      let peek = get len in
      if len = s.len then printfn "Peek: %S" peek
      else printfn "Peek: %S (full: %S)" peek (get s.len);
      peek

let write_str b src =
  let len = String.length src in
  match B.reserve b ~len with
  | None -> assert false
  | Some dst_pos ->
      let dst = B.buffer b in
      Bytes.blit_string ~dst ~dst_pos ~src ~src_pos:0 ~len;
      B.commit b ~len

let%expect_test "bip buffers" =
  let buf_size = 16 in
  let b = B.create (Bytes.create buf_size) ~len:buf_size in
  assert (B.is_empty b);
  [%expect {| |}];
  let () =
    let mystr = "Test Foo|Bar" in
    let mystr_len = String.length mystr in
    write_str b mystr;
    assert (B.length b = mystr_len)
  in
  [%expect {| |}];
  (* Now we try to read 4 characters *)
  let () =
    let read_len = 8 in
    let (_ : string) = peek_str b ~len:read_len in
    B.junk b ~len:read_len
  in
  [%expect
    {|
    Requested 8. Available 12
    Peek: "Test Foo" (full: "Test Foo|Bar") |}];
  ignore (peek_str b ~len:4);
  [%expect {|
    Requested 4. Available 4
    Peek: "|Bar" |}]

let%expect_test "fill buffer" =
  let str = "foo bar baz foo" in
  let len = String.length str in
  let b = B.create (Bytes.create len) ~len in
  write_str b str;
  let str' = peek_str b ~len in
  assert (String.equal str str');
  [%expect {|
    Requested 15. Available 15
    Peek: "foo bar baz foo" |}]

let%expect_test "reserve overflow" =
  let buf_size = 16 in
  let b = B.create (Bytes.create buf_size) ~len:buf_size in
  let len = 17 in
  (match B.reserve b ~len with None -> () | Some _ -> assert false);
  [%expect {||}]

let%expect_test "unused space" =
  let buf_size = 16 in
  let half = buf_size / 2 in
  let b = B.create (Bytes.create buf_size) ~len:buf_size in
  let unused = B.unused_space b in
  printfn "unused space: %d" unused;
  [%expect {|
    unused space: 16 |}];
  assert (unused = buf_size);
  write_str b (String.make half 'a');
  assert (B.unused_space b = half);
  write_str b (String.make (pred half) 'b');
  B.junk b ~len:half;
  let unused = B.unused_space b in
  printfn "unused space: %d" unused;
  assert (unused = 9);
  [%expect {|
    unused space: 9 |}];
  let b = B.create (Bytes.create buf_size) ~len:buf_size in
  write_str b (String.make half 'a');
  assert (B.length b = half);
  B.junk b ~len:1;
  assert (B.length b = pred half);
  let unused = B.unused_space b in
  printfn "unused space: %d" unused;
  assert (unused = 9);
  [%expect {| unused space: 9 |}]
