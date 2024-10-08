open State

let halve secret =
  let size = String.length secret in
  let half = size - size / 2 in
  String.(sub secret 0 half, sub secret (size - half) half)

let p_hash (hmac, hmac_n) key seed len =
  let rec expand a to_go =
    let res = hmac ~key (a ^ seed) in
    if to_go > hmac_n then
      res ^ expand (hmac ~key a) (to_go - hmac_n)
    else String.sub res 0 to_go
  in
  expand (hmac ~key seed) len

let prf_mac = function
  | `RSA_WITH_AES_256_GCM_SHA384
  | `DHE_RSA_WITH_AES_256_GCM_SHA384
  | `ECDHE_RSA_WITH_AES_256_GCM_SHA384
  | `ECDHE_RSA_WITH_AES_256_CBC_SHA384
  | `ECDHE_ECDSA_WITH_AES_256_CBC_SHA384
  | `ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 -> (module Digestif.SHA384 : Digestif.S)
  | _ -> (module Digestif.SHA256 : Digestif.S)

let pseudo_random_function version cipher len secret label seed =
  let labelled = label ^ seed in
  match version with
  | `TLS_1_1 | `TLS_1_0 ->
     let (s1, s2) = halve secret in
     let md5 = p_hash ((fun ~key s -> Digestif.MD5.(to_raw_string (hmac_string ~key s))), Digestif.MD5.digest_size) s1 labelled len
     and sha = p_hash ((fun ~key s -> Digestif.SHA1.(to_raw_string (hmac_string ~key s))), Digestif.SHA1.digest_size) s2 labelled len in
     Mirage_crypto.Uncommon.xor md5 sha
  | `TLS_1_2 ->
     let module D = (val (prf_mac cipher)) in
     p_hash ((fun ~key s -> D.(to_raw_string (hmac_string ~key s))), D.digest_size) secret labelled len

let key_block version cipher len master_secret seed =
  pseudo_random_function version cipher len master_secret "key expansion" seed

let hash version cipher data =
  match version with
  | `TLS_1_0 | `TLS_1_1 -> Digestif.(MD5.(to_raw_string (digest_string data)) ^ SHA1.(to_raw_string (digest_string data)))
  | `TLS_1_2 ->
    let module H = (val prf_mac cipher) in
    H.(to_raw_string (digest_string data))

let finished version cipher master_secret label ps =
  let data = String.concat "" ps in
  let seed = hash version cipher data in
  pseudo_random_function version cipher 12 master_secret label seed

let divide_keyblock key mac iv buf =
  let c_mac, rt0 = Core.split_str buf mac in
  let s_mac, rt1 = Core.split_str rt0 mac in
  let c_key, rt2 = Core.split_str rt1 key in
  let s_key, rt3 = Core.split_str rt2 key in
  let c_iv , s_iv = Core.split_str rt3 iv
  in
  (c_mac, s_mac, c_key, s_key, c_iv, s_iv)

let derive_master_secret version (session : session_data) premaster log =
  let prf = pseudo_random_function version session.ciphersuite 48 premaster in
  if session.extended_ms then
    let session_hash =
      let data = String.concat "" log in
      hash version session.ciphersuite data
    in
    prf "extended master secret" session_hash
  else
    prf "master secret" (session.common_session_data.client_random ^ session.common_session_data.server_random)

let initialise_crypto_ctx version (session : session_data) =
  let open Ciphersuite in
  let client_random = session.common_session_data.client_random
  and server_random = session.common_session_data.server_random
  and master = session.common_session_data.master_secret
  and cipher = session.ciphersuite
  in

  let pp = ciphersuite_privprot cipher in

  let c_mac, s_mac, c_key, s_key, c_iv, s_iv =
    let iv_l = match version with
      | `TLS_1_0 -> Some ()
      | _ -> None
    in
    let key_len, iv_len, mac_len = Ciphersuite.key_length iv_l pp in
    let kblen = 2 * key_len + 2 * mac_len + 2 * iv_len
    and rand = server_random ^ client_random
    in
    let keyblock = key_block version cipher kblen master rand in
    divide_keyblock key_len mac_len iv_len keyblock
  in

  let context cipher_k iv mac_k =
    let open Crypto.Ciphers in
    let cipher_st =
      let iv_mode = match version with
        | `TLS_1_0 -> Iv iv
        | _ -> Random_iv
      in
      get_cipher ~secret:cipher_k ~hmac_secret:mac_k ~iv_mode ~nonce:iv pp
    and sequence = 0L in
    { cipher_st ; sequence }
  in

  let c_context = context c_key c_iv c_mac
  and s_context = context s_key s_iv s_mac in

  (c_context, s_context)
