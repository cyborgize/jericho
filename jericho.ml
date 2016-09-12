open Printf

module J = Yojson.Safe

type log_severity = Debug | Info | Warn | Error

type 'a log_print = ?exn:exn -> ('a, unit, string, unit) format4 -> 'a

let log_level : log_severity option ref = ref None

let log_from facility =
  let print severity ?exn:_ (* FIXME *) fmt =
    ksprintf begin fun message ->
      match !log_level with
      | Some log_severity when severity >= log_severity ->
        let severity =
          match severity with
          | Debug -> "debug"
          | Info -> "info"
          | Warn -> "warn"
          | Error -> "error"
        in
        fprintf stderr "[%s:%s] %s" facility severity message
      | _ -> ()
    end fmt
  in
  object
    method debug : 'a. 'a log_print = print Debug
    method info : 'a. 'a log_print = print Info
    method warn : 'a. 'a log_print = print Warn
    method error : 'a. 'a log_print = print Error
  end

let log = log_from "jericho"

let server_timestamp = `Assoc [ ".sv", `String "timestamp"; ]

let priority x = ".priority", `Float x

type print = [ `Pretty | `Silent ]

type order = [ `Key | `Value | `Priority | `Field of string ]

let string_of_print = function
  | `Pretty -> "pretty"
  | `Silent -> "silent"

let string_of_order = function
  | `Key -> "$key"
  | `Value -> "$value"
  | `Priority -> "$priority"
  | `Field s -> s

let curl_setup h ?(timeout=30) url =
  let open Curl in
  set_url h url;
  set_nosignal h true;
  set_connecttimeout h 30;
  set_followlocation h false;
  set_encoding h CURL_ENCODING_ANY;
  set_timeout h timeout;
  ()

type http_action = [ `GET | `POST | `DELETE | `PUT | `PATCH ]

let string_of_http_action = function
  | `GET -> "GET"
  | `POST -> "POST"
  | `DELETE -> "DELETE"
  | `PUT -> "PUT"
  | `PATCH -> "PATCH"

let make_url_args args =
  let urlencode = Netencoding.Url.encode ~plus:true in
  let args = (List.map (fun (k, v) -> k ^ "=" ^ urlencode v) args) in
  String.concat "&" args

let event_stream url =
  let (chunks, push) = Lwt_stream.create () in
  let rec curl () =
    let h = Curl.init () in
    let rec loop url =
      let headers = ref [] in
      let header s =
        let k, v =
          match String.index s ':' with
          | i -> String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1)
          | exception Not_found -> "", s
        in
        headers := (String.lowercase k, String.trim v) :: !headers;
        String.length s
      in
      let write s =
        let len = String.length s in
        push (Some (Bytes.of_string s, ref 0, ref len));
        len
      in
      let open Curl in
      reset h;
      curl_setup h ~timeout:0 url;
      set_httpheader h [ "Accept: text/event-stream"; ];
      set_headerfunction h header;
      set_writefunction h write;
      match%lwt Curl_lwt.perform h with
      | CURLE_OK ->
        begin match get_httpcode h with
        | 200 -> log #info "curl ok"; Lwt.return `Ok
        | code when code / 100 = 3 ->
          let%lwt url = Lwt.wrap2 List.assoc "location" !headers in
          if !log_level = Some Debug then log #debug "http %d location %s" code url;
          loop url
        | code -> Lwt.return (`Error (sprintf "http: %d" code))
        end
      | code ->
        let msg = sprintf "curl (%d) %s" (Curl.errno code) (Curl.strerror code) in
        log #error "curl error: %s" msg;
        Lwt.return (`Error msg)
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
    match J.from_string s with
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
        if !log_level = Some Debug then log #debug "stream comment %s" s;
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

type event = [ `AuthRevoked | `Cancel | `KeepAlive | `Patch of string * J.json | `Put of string * J.json ]

type t = <
  get : ?shallow:bool -> ?export:bool -> ?order_by:order ->
    ?start_at:string -> ?end_at:string -> ?equal_to:string ->
    ?limit_to_first:int -> ?limit_to_last:int -> ?print:print ->
    string -> J.json option Lwt.t;
  set : ?pretty:bool -> string -> J.json -> bool Lwt.t;
  update : ?pretty:bool -> string -> J.json -> bool Lwt.t;
  update_multi : string -> (string * J.json) list -> bool Lwt.t;
  push : string -> J.json -> string option Lwt.t;
  delete : string -> bool Lwt.t;
  event_stream : string -> event Lwt_stream.t
>

let option_map f x = match x with Some x -> Some (f x) | None -> None

let make ~auth base_url =
  let log_error ?exn action path error = log #error ?exn "%s %s : %s" (string_of_http_action action) path error in
  let invalid_response ?exn action k s = log_error ?exn action k (sprintf "invalid response : %s" s); Lwt.return_none in
  let query action ?(pretty=false) ?(args=[]) ?print path data =
    let body =
      match data with
      | None -> None
      | Some data ->
      match pretty with
      | true -> Some (J.pretty_to_string data)
      | false -> Some (J.to_string data)
    in
    let args = ("auth", Some auth) :: ("print", option_map string_of_print print) :: args in
    let args =
      List.filter (function (k, Some v) -> true | _ -> false) args |>
      List.map (function (k, Some v) -> k, v | _ -> assert false)
    in
    let url = sprintf "%s%s.json?%s" base_url path (make_url_args args) in
    let open Curl in
    let h = init () in
    curl_setup h url;
    begin match action with
    | `GET -> ()
    | `DELETE -> set_customrequest h "DELETE"
    | `POST -> set_post h true
    | `PUT -> set_post h true; set_customrequest h "PUT"
    | `PATCH -> set_post h true; set_customrequest h "PATCH"
    end;
    begin match body with
    | None -> ()
    | Some body ->
      set_httpheader h [ "Content-Type: application/json"; ];
      set_postfields h body;
      set_postfieldsize h (String.length body)
    end;
    let b = Buffer.create 10 in
    set_writefunction h (fun s -> Buffer.add_string b s; String.length s);
    match%lwt Curl_lwt.perform h with
    | CURLE_OK ->
      begin match get_httpcode h with
      | 200 -> log #info "curl ok"; Lwt.return (`Ok (Buffer.contents b))
      | code -> Lwt.return (`Error (sprintf "http: %d" code))
      end
    | code ->
      let msg = sprintf "curl (%d) %s" (Curl.errno code) (Curl.strerror code) in
      log #error "curl error: %s" msg;
      Lwt.return (`Error msg)
  in
  let bool_query action ?pretty path data =
    match%lwt query action ?pretty ~print:`Silent path data with
    | `Ok _ -> Lwt.return_true
    | `Error error -> log_error action path error; Lwt.return_false
  in
  let json_string s = J.to_string (`String s) in
  (object
    method get ?(shallow=false) ?(export=false) ?order_by ?start_at ?end_at ?equal_to ?limit_to_first ?limit_to_last ?print k =
      let args = [
        "shallow", (if shallow then Some "true" else None);
        "orderBy", option_map (fun x -> json_string (string_of_order x)) order_by;
        "startAt", option_map json_string start_at;
        "endAt", option_map json_string end_at;
        "equalTo", option_map json_string equal_to;
        "limitToFirst", option_map string_of_int limit_to_first;
        "limitToLast", option_map string_of_int limit_to_last;
        "format", (if export then Some "export" else None);
      ] in
      match%lwt query `GET ~args ?print k None with
      | `Error error -> log_error `GET k error; Lwt.return_none
      | `Ok s ->
      match J.from_string s with
      | json -> Lwt.return_some json
      | exception exn -> invalid_response ~exn `POST k s

    method set ?pretty k v = bool_query `PUT ?pretty k (Some v)

    method update ?pretty k v = bool_query `PATCH ?pretty k (Some v)

    method update_multi k l = bool_query `PATCH k (Some (`Assoc l))

    method push k v =
      match%lwt query `POST k (Some v) with
      | `Error error -> log_error `POST k error; Lwt.return_none
      | `Ok s ->
      match J.from_string s with
      | `Assoc [ "name", `String name; ] -> Lwt.return_some name
      | _ -> invalid_response `POST k s
      | exception exn -> invalid_response ~exn `POST k s

    method delete k = bool_query `DELETE k None

    method event_stream k = event_stream (sprintf "%s%s.json?%s" base_url k (make_url_args [ "auth", auth; ]))
  end : t)
