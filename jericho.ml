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

let make ~auth base_url =
  let log_error ?exn action path error = log #error ?exn "%s %s : %s" (Web.string_of_http_action action) path error in
  let query action ?(args=[]) ?print path data =
    let body = match data with Some data -> Some ("application/json", Yojson.to_string data) | None -> None in
    let args = ("auth", Some auth) :: ("print", Option.map string_of_print print) :: args in
    let args = List.filter_map (function (k, Some v) -> Some (k, v) | _ -> None) args in
    let url = sprintf "%s%s.json?%s" base_url path (Web.make_url_args args) in
    Web.http_query_lwt ~verbose:(log #level = `Debug) ?body action url
  in
  let bool_query action path data =
    match%lwt query action ~print:`Silent path data with
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

    method set k v = bool_query `PUT k (Some v)

    method update k v = bool_query `PATCH k (Some v)

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
  end
