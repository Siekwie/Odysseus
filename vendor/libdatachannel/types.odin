package libdatachannel

import "core:c"

// C API types from libdatachannel rtc/rtc.h.
// C enums are int; keep them i32-sized.

ERR_SUCCESS   :: 0
ERR_INVALID   :: -1
ERR_FAILURE   :: -2
ERR_NOT_AVAIL :: -3
ERR_TOO_SMALL :: -4

DEFAULT_MTU               :: 1280
DEFAULT_MAX_FRAGMENT_SIZE :: u16(DEFAULT_MTU - 12 - 8 - 40)

State :: enum i32 {
	New          = 0,
	Connecting   = 1,
	Connected    = 2,
	Disconnected = 3,
	Failed       = 4,
	Closed       = 5,
}

Ice_State :: enum i32 {
	New          = 0,
	Checking     = 1,
	Connected    = 2,
	Completed    = 3,
	Failed       = 4,
	Disconnected = 5,
	Closed       = 6,
}

Gathering_State :: enum i32 {
	New        = 0,
	Inprogress = 1,
	Complete   = 2,
}

Signaling_State :: enum i32 {
	Stable               = 0,
	Have_Local_Offer     = 1,
	Have_Remote_Offer    = 2,
	Have_Local_Pranswer  = 3,
	Have_Remote_Pranswer = 4,
}

Log_Level :: enum i32 {
	None    = 0,
	Fatal   = 1,
	Error   = 2,
	Warning = 3,
	Info    = 4,
	Debug   = 5,
	Verbose = 6,
}

Certificate_Type :: enum i32 {
	Default = 0,
	Ecdsa   = 1,
	Rsa     = 2,
}

Codec :: enum i32 {
	H264 = 0,
	Vp8  = 1,
	Vp9  = 2,
	H265 = 3,
	Av1  = 4,
	Opus = 128,
	Pcmu = 129,
	Pcma = 130,
	Aac  = 131,
	G722 = 132,
}

Direction :: enum i32 {
	Unknown  = 0,
	Sendonly = 1,
	Recvonly = 2,
	Sendrecv = 3,
	Inactive = 4,
}

Transport_Policy :: enum i32 {
	All   = 0,
	Relay = 1,
}

Nal_Unit_Separator :: enum i32 {
	Length               = 0,
	Long_Start_Sequence  = 1, // 00 00 00 01 — typical FFmpeg Annex B
	Short_Start_Sequence = 2, // 00 00 01
	Start_Sequence       = 3,
}

Obu_Packetization :: enum i32 {
	Obu           = 0,
	Temporal_Unit = 1,
}

Log_Callback              :: proc "c" (level: Log_Level, message: cstring)
Description_Callback      :: proc "c" (pc: c.int, sdp, type: cstring, ptr: rawptr)
Candidate_Callback        :: proc "c" (pc: c.int, cand, mid: cstring, ptr: rawptr)
State_Change_Callback     :: proc "c" (pc: c.int, state: State, ptr: rawptr)
Ice_State_Change_Callback :: proc "c" (pc: c.int, state: Ice_State, ptr: rawptr)
Gathering_State_Callback  :: proc "c" (pc: c.int, state: Gathering_State, ptr: rawptr)
Signaling_State_Callback  :: proc "c" (pc: c.int, state: Signaling_State, ptr: rawptr)
Data_Channel_Callback     :: proc "c" (pc: c.int, dc: c.int, ptr: rawptr)
Track_Callback            :: proc "c" (pc: c.int, tr: c.int, ptr: rawptr)
Open_Callback             :: proc "c" (id: c.int, ptr: rawptr)
Closed_Callback           :: proc "c" (id: c.int, ptr: rawptr)
Error_Callback            :: proc "c" (id: c.int, error: cstring, ptr: rawptr)
Message_Callback          :: proc "c" (id: c.int, message: cstring, size: c.int, ptr: rawptr)
Interceptor_Callback      :: proc "c" (pc: c.int, message: cstring, size: c.int, ptr: rawptr) -> rawptr
Buffered_Amount_Callback  :: proc "c" (id: c.int, ptr: rawptr)
Available_Callback        :: proc "c" (id: c.int, ptr: rawptr)
Pli_Handler_Callback      :: proc "c" (tr: c.int, ptr: rawptr)
Remb_Handler_Callback     :: proc "c" (tr: c.int, bitrate: c.uint, ptr: rawptr)

Frame_Info :: struct {
	timestamp:         u32,
	payload_type:      u8,
	timestamp_seconds: f64, // negative means not available
}

Frame_Callback :: proc "c" (tr: c.int, data: cstring, size: c.int, info: ^Frame_Info, ptr: rawptr)

Configuration :: struct {
	ice_servers:                     [^]cstring,
	ice_servers_count:               c.int,
	proxy_server:                    cstring,
	bind_address:                    cstring,
	certificate_type:                Certificate_Type,
	certificate_pem_file:            cstring,
	key_pem_file:                    cstring,
	key_pem_pass:                    cstring,
	ice_transport_policy:            Transport_Policy,
	enable_ice_tcp:                  bool,
	enable_ice_udp_mux:              bool,
	disable_auto_negotiation:        bool,
	force_media_transport:           bool,
	port_range_begin:                u16,
	port_range_end:                  u16,
	mtu:                             c.int,
	max_message_size:                c.int,
	disable_fingerprint_verification: bool,
}

Local_Description_Init :: struct {
	ice_ufrag: cstring,
	ice_pwd:   cstring,
}

Reliability :: struct {
	unordered:            bool,
	unreliable:           bool,
	max_packet_life_time: c.uint,
	max_retransmits:      c.uint,
}

Data_Channel_Init :: struct {
	reliability:  Reliability,
	protocol:     cstring,
	negotiated:   bool,
	manual_stream: bool,
	stream:       u16,
}

Track_Init :: struct {
	direction:    Direction,
	codec:        Codec,
	payload_type: c.int,
	ssrc:         u32,
	mid:          cstring,
	name:         cstring,
	msid:         cstring,
	track_id:     cstring,
	profile:      cstring,
}

Packetizer_Init :: struct {
	ssrc:                    u32,
	cname:                   cstring,
	payload_type:            u8,
	clock_rate:              u32,
	sequence_number:         u16,
	timestamp:               u32,
	max_fragment_size:       u16,
	nal_separator:           Nal_Unit_Separator,
	obu_packetization:       Obu_Packetization,
	playout_delay_id:        u8,
	playout_delay_min:       u16,
	playout_delay_max:       u16,
	color_space_id:          u8,
	color_chroma_siting_horz: u8,
	color_chroma_siting_vert: u8,
	color_range:             u8,
	color_primaries:         u8,
	color_transfer:          u8,
	color_matrix:            u8,
}

#assert(offset_of(Packetizer_Init, payload_type) == 16)
#assert(offset_of(Packetizer_Init, clock_rate) == 20)
#assert(offset_of(Packetizer_Init, max_fragment_size) == 32)
#assert(offset_of(Packetizer_Init, nal_separator) == 36)

Ssrc_For_Type_Init :: struct {
	ssrc:     u32,
	name:     cstring,
	msid:     cstring,
	track_id: cstring,
}

Sctp_Settings :: struct {
	recv_buffer_size:              c.int,
	send_buffer_size:              c.int,
	max_chunks_on_queue:           c.int,
	initial_congestion_window:     c.int,
	max_burst:                     c.int,
	congestion_control_module:     c.int,
	delayed_sack_time_ms:          c.int,
	min_retransmit_timeout_ms:     c.int,
	max_retransmit_timeout_ms:     c.int,
	initial_retransmit_timeout_ms: c.int,
	max_retransmit_attempts:       c.int,
	heartbeat_interval_ms:         c.int,
}

// Constrained Baseline profile string browsers accept for WebRTC H.264.
H264_WEBRTC_PROFILE :: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
