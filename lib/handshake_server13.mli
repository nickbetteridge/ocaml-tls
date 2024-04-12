open State
open Core

val answer_client_hello: ?embed_quic_transport_params:(Cstruct.t option -> Cstruct.t option) ->
    hrr:bool ->
    handshake_state ->
    client_hello ->
    Cstruct.t -> (handshake_return, failure) result

val handle_handshake : ?embed_quic_transport_params:(Cstruct.t option -> Cstruct.t option) -> server13_handshake_state -> handshake_state -> Cstruct.t -> (handshake_return, failure) result
