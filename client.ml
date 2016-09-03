open Prelude
open ExtLib
open Printf

module J = Yojson.Safe

let log = Log.from "client"

let () =
  let auth = ref None in
  let base_url = ref None in
  let action = ref None in
  let set_action x = action := Some x in
  let args =
    let open ExtArg in [
      may_str "auth" auth " authentication token (required)";
      may_str "base-url" base_url " firebase realtime database base url (required)";
      "-get", String (fun k -> set_action (`Get k)), "<key> get the value at the specified key";
      "-set", two_strings (fun k v -> set_action (`Set (k, v))), "<key> <value> #set the value at the specified key";
      "-push", two_strings (fun k v -> set_action (`Push (k, v))), "<key> <value> #add the specified value under the specified key";
      "-stream", String (fun k -> set_action (`Stream k)), "<key> listen for event stream for the specified key";
    ]
  in
  ExtArg.parse args;
  Log.set_filter `Debug;
  match !auth, !base_url, !action with
  | None, _, _ | _, None, _ | _, _, None ->
    log #error "authentication token, base url, and an action must be provided";
    ExtArg.usage args;
    exit 1
  | Some auth, Some base_url, Some action ->
  Lwt_main.run begin
    let jericho = Jericho.make ~auth base_url in
    match action with
    | `Get k ->
      let%lwt result = jericho #get k in
      begin match result with
      | Some v -> log #info "get %s = %s" k (J.to_string v)
      | None -> log #error "get %s : error" k
      end;
      Lwt.return_unit
    | `Set (k, v) ->
      let%lwt result = jericho #set k (J.from_string v) in
      begin match result with
      | true -> log #info "set %s = %s" k v
      | false -> log #info "set %s : error" k
      end;
      Lwt.return_unit
    | `Push (k, v) ->
      let%lwt result = jericho #push k (J.from_string v) in
      begin match result with
      | Some s -> log #info "push %s %s = %s" k s v
      | None -> log #info "push %s : error" k
      end;
      Lwt.return_unit
    | `Stream k ->
    let stream = jericho #event_stream "/" in
    let%lwt () =
      Lwt_stream.iter begin function
        | `Put (k, v) -> log #info "put %s %s" k (J.to_string v)
        | `Patch (k, v) -> log #info "patch %s %s" k (J.to_string v)
        | `KeepAlive -> log #debug "keep-alive"
        | `Cancel -> log #warn "cancel"
        | `AuthRevoked -> log #warn "auth revoked"
      end stream
    in
    Lwt.return_unit
  end
