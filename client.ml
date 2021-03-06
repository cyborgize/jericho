open Printf

module J = Yojson.Safe

let log = Jericho.log_from "client"

let () =
  let auth = ref None in
  let base_url = ref None in
  let action = ref None in
  let set_action x = action := Some x in
  let args =
    let open Arg in
    let may_string v = String (fun s -> v := Some s) in
    let two_strings f = let s1 = ref "" in Tuple [ String ((:=) s1); String (fun s2 -> f !s1 s2); ] in
    [
      "-auth", may_string auth, " authentication token (required)";
      "-base-url", may_string base_url, " firebase realtime database base url (required)";
      "-get", String (fun k -> set_action (`Get k)), "<key> get the value at the specified key";
      "-set", two_strings (fun k v -> set_action (`Set (k, v))), "<key> <value> #set the value at the specified key";
      "-push", two_strings (fun k v -> set_action (`Push (k, v))), "<key> <value> #add the specified value under the specified key";
      "-stream", String (fun k -> set_action (`Stream k)), "<key> listen for event stream for the specified key";
    ]
  in
  Arg.parse args (fun _ -> ()) "";
  Jericho.log_level := Some Jericho.Debug;
  match !auth, !base_url, !action with
  | None, _, _ | _, None, _ | _, _, None ->
    log #error "authentication token, base url, and an action must be provided";
    Arg.usage args "";
    exit 1
  | Some auth, Some base_url, Some action ->
  Lwt_main.run begin
    let jericho = Jericho.make ~auth base_url in
    match action with
    | `Get k ->
      let%lwt v = jericho #get k in
      log #info "get %s = %s" k (J.to_string v);
      Lwt.return_unit
    | `Set (k, v) ->
      let%lwt () = jericho #set k (J.from_string v) in
      log #info "set %s" k;
      Lwt.return_unit
    | `Push (k, v) ->
      let%lwt name = jericho #push k (J.from_string v) in
      log #info "push %s %s = %s" k name v;
      Lwt.return_unit
    | `Stream k ->
    let stream = jericho #event_stream k in
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
