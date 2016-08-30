open Prelude
open ExtLib
open Printf

let log = Log.from "test"

let () =
  let auth = ref None in
  let base_url = ref None in
  let args =
    let open ExtArg in [
      may_str "auth" auth " authentication token (required)";
      may_str "base-url" base_url " firebase realtime database base url (required)";
    ]
  in
  ExtArg.parse args;
  Log.set_filter `Debug;
  match !auth, !base_url with
  | None, _ | _, None ->
    log #error "both authentication token and base url must be provided"
  | Some auth, Some base_url ->
  Lwt_main.run begin
    let jericho = Jericho.make ~auth base_url in
    let%lwt () =
      match%lwt jericho #push "/test/messages" (`String "hello, world!") with
      | Some name -> log #info "ok: %s" name; Lwt.return_unit
      | None -> Lwt.return_unit
    in
    Lwt.return_unit
  end
