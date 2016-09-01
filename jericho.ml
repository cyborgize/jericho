open Prelude
open ExtLib
open Printf

let log = Log.from "jericho"

let server_timestamp = `Assoc [ ".sv", `String "timestamp"; ]

let priority x = ".priority", `Float x

let string_of_print = function
  | `Pretty -> "pretty"
  | `Silent -> "silent"

let string_of_order = function
  | `Key -> "$key"
  | `Value -> "$value"
  | `Priority -> "$priority"
  | `Field s -> s

let event_stream url =
  let check h = Curl.get_httpcode h = 200 in
  let inner_error = ref `None in
  let error code = sprintf "curl (%d) %s" (Curl.errno code) (Curl.strerror code) in
  let inner_error_msg () =
    match !inner_error with
    | `None -> error Curl.CURLE_WRITE_ERROR
    | `Write exn -> sprintf "write error : %s" @@ Exn.to_string exn
    | `Http code -> sprintf "http : %d" code
  in
  let (chunks, push) = Lwt_stream.create () in
  let rec curl () =
    let rec loop url =
      try%lwt
        let headers = ref [] in
        Web.Http_lwt.with_curl_cache begin fun h ->
          Curl.set_url h url;
          Web.curl_default_setup h;
          Curl.set_timeout h 0;
          Curl.set_httpheader h [ "Accept: text/event-stream"; ];
          Curl.set_headerfunction h begin fun s ->
            let (k, v) = try Stre.splitc s ':' with Not_found -> "", s in
            tuck headers (String.lowercase k, String.strip v);
            String.length s
          end;
          Curl.set_writefunction h begin fun s ->
            try
              match check h with
              | true ->
                let len = String.length s in
                push (Some (Bytes.of_string s, ref 0, ref len));
                len
              | false -> inner_error := `Http (Curl.get_httpcode h); 0
            with exn -> inner_error := `Write exn; 0
          end;
          match%lwt Curl_lwt.perform h with
          | Curl.CURLE_OK ->
            begin match Curl.get_httpcode h with
            | 200 -> log #info "curl ok"; Lwt.return `Ok
            | code when code / 100 = 3 ->
              let%lwt url = Lwt.wrap2 List.assoc "location" !headers in
              log #info "http %d location %s" code url;
              loop url
            | code -> Lwt.return (`Error (sprintf "http: %d" code))
            end
          | Curl.CURLE_WRITE_ERROR ->
            let msg = inner_error_msg () in
            log #error "curl write error: %s" msg;
            Lwt.return (`Error msg)
          | code ->
            let msg = error code in
            log #error "curl error: %s" msg;
            Lwt.return (`Error msg)
        end
      with exn ->
        Exn_lwt.fail ~exn "http_get_io_lwt (%s)" (inner_error_msg ())
    in
    match%lwt loop url with
    | `Ok -> log #info "ok"; curl ()
    | `Error error -> log #error "error %s" error; Lwt.return_unit
  in
  let rec read buf written ofs size =
    match size with
    | 0 -> Lwt.return written
    | _ ->
    let thread = Lwt_stream.peek chunks in
    match Lwt.is_sleeping thread with
    | true when written > 0 -> Lwt.return written
    | _ ->
    match%lwt thread with
    | None -> Lwt.return written
    | Some (chunk, start, remaining) ->
    let write = min size !remaining in
    Lwt_bytes.blit_from_bytes chunk !start buf ofs write;
    let%lwt () =
      match write < !remaining with
      | true -> start := !start + write; remaining := !remaining - write; Lwt.return_unit
      | false -> Lwt_stream.junk chunks
    in
    read buf (written + write) (ofs + write) (size - write)
  in
  let read buf ofs size = read buf 0 ofs size in
  let chan = Lwt_io.make ~mode:Lwt_io.Input read in
  let lines = Lwt_io.read_lines chan in
  Lwt.async curl;
  let split_string s i =
    let len = String.length s in
    let j = if i < len - 1 && s.[i + 1] = ' ' then i + 2 else i + 1 in
    String.sub s 0 i, String.sub s j (len - j)
  in
  let zero = "", [] in
  let string_of_data data = String.concat "\n" (List.rev data) in
  let get_kv data =
    let s = string_of_data data in
    let error ?exn s = log #error ?exn "get_kv %s" s; "", `Null in
    match Yojson.Safe.from_string s with
    | `Assoc [ "path", `String k; "data", v; ]
    | `Assoc [ "data", v; "path", `String k; ] -> k, v
    | _ -> error s
    | exception exn -> error ~exn s
  in
  let check_null data =
    if data <> ["null"] then log #warn "keep-alive data %s" (string_of_data data)
  in
  Lwt_stream.from begin fun () ->
    let rec process_line e =
      match%lwt Lwt_stream.get lines with
      | None -> Lwt.return_none
      | Some "" -> dispatch_event e
      | Some s when s.[0] = ':' ->
        if log #level = `Debug then log #debug "stream comment %s" s;
        process_line e
      | Some s ->
      match String.index s ':' with
      | i -> process_event e (split_string s i)
      | exception Not_found -> process_event e (s, "")
    and process_event (event, data as e) (k, v) =
      match k with
      | "event" -> process_line (v, data)
      | "data" -> process_line (event, v :: data)
      | _ -> log #warn "ignored event %s" k; process_line e
    and dispatch_event = function
      | _, [] -> process_line zero
      | "", _ -> log #warn "no event"; process_line zero
      | "put", data -> Lwt.return_some (`Put (get_kv data))
      | "patch", data -> Lwt.return_some (`Patch (get_kv data))
      | "keep-alive", data -> check_null data; Lwt.return_some `KeepAlive
      | "cancel", data -> check_null data; Lwt.return_some `Cancel
      | "auth_revoked", data -> check_null data; Lwt.return_some `AuthRevoked
      | event, data -> log #warn "unsupported event %s %s" event (string_of_data data); process_line zero
    in
    process_line zero
  end

let make ~auth base_url =
  let log_error ?exn action path error = log #error ?exn "%s %s : %s" (Web.string_of_http_action action) path error in
  let query action ?(pretty=false) ?(args=[]) ?print path data =
    let body =
      match data with
      | None -> None
      | Some data ->
      let data =
        match pretty with
        | true -> Yojson.Safe.pretty_to_string ~std:true data
        | false -> Yojson.Safe.to_string ~std:true data
      in
      Some ("application/json", data)
    in
    let args = ("auth", Some auth) :: ("print", Option.map string_of_print print) :: args in
    let args = List.filter_map (function (k, Some v) -> Some (k, v) | _ -> None) args in
    let url = sprintf "%s%s.json?%s" base_url path (Web.make_url_args args) in
    Web.http_query_lwt ~verbose:(log #level = `Debug) ?body action url
  in
  let bool_query action ?pretty path data =
    match%lwt query action ?pretty ~print:`Silent path data with
    | `Ok _ -> Lwt.return_true
    | `Error error -> log_error action path error; Lwt.return_false
  in
  object
    method get ?(shallow=false) ?(export=false) ?order_by ?start_at ?end_at ?equal_to ?limit_to_first ?limit_to_last ?print k =
      let args = [
        "shallow", (if shallow then Some "true" else None);
        "orderBy", Option.map string_of_order order_by;
        "startAt", start_at;
        "endAt", end_at;
        "equalTo", equal_to;
        "limitToFirst", Option.map string_of_int limit_to_first;
        "limitToLast", Option.map string_of_int limit_to_last;
        "format", (if export then Some "export" else None);
      ] in
      query `GET ~args ?print k None

    method set ?pretty k v = bool_query `PUT ?pretty k (Some v)

    method update ?pretty k v = bool_query `PATCH ?pretty k (Some v)

    method update_multi k l = bool_query `PATCH k (Some (`Assoc l))

    method push k v =
      match%lwt query `POST k (Some v) with
      | `Ok s ->
        let invalid_response ?exn () = log_error ?exn `POST k (sprintf "invalid response : %s" s); Lwt.return_none in
        begin match Yojson.Safe.from_string s with
        | `Assoc [ "name", `String name; ] -> Lwt.return_some name
        | _ -> invalid_response ()
        | exception exn -> invalid_response ~exn ()
        end
      | `Error error -> log_error `POST k error; Lwt.return_none

    method delete k = bool_query `DELETE k None

    method event_stream k = event_stream (sprintf "%s%s.json?%s" base_url k (Web.make_url_args [ "auth", auth; ]))
  end
