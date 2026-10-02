package libdatachannel

import "core:c"

// libdatachannel C API (rtc/rtc.h, 0.20+) used for WebRTC peer connections and
// RTP packetization. Signaling (SDP / ICE over WebSocket) stays in the Odin
// HTTP server; this library does the media transport.
//
// Windows links the vendored import library; the DLLs under bin/ are copied
// next to the executable by build.ps1. Linux and macOS link libdatachannel
// from the system or from scripts/fetch-libs.sh (see build.sh).

when ODIN_OS == .Windows {
	foreign import lib "lib/datachannel.lib"
} else {
	foreign import lib "system:datachannel"
}

ok :: proc(err: c.int) -> bool {
	return err == ERR_SUCCESS
}

@(default_calling_convention = "c")
foreign lib {
	rtcInitLogger :: proc(level: Log_Level, cb: Log_Callback) ---
	rtcSetUserPointer :: proc(id: c.int, ptr: rawptr) ---
	rtcGetUserPointer :: proc(id: c.int) -> rawptr ---

	rtcCreatePeerConnection :: proc(config: ^Configuration) -> c.int ---
	rtcClosePeerConnection :: proc(pc: c.int) -> c.int ---
	rtcDeletePeerConnection :: proc(pc: c.int) -> c.int ---

	rtcSetLocalDescriptionCallback :: proc(pc: c.int, cb: Description_Callback) -> c.int ---
	rtcSetLocalCandidateCallback :: proc(pc: c.int, cb: Candidate_Callback) -> c.int ---
	rtcSetStateChangeCallback :: proc(pc: c.int, cb: State_Change_Callback) -> c.int ---
	rtcSetIceStateChangeCallback :: proc(pc: c.int, cb: Ice_State_Change_Callback) -> c.int ---
	rtcSetGatheringStateChangeCallback :: proc(pc: c.int, cb: Gathering_State_Callback) -> c.int ---
	rtcSetSignalingStateChangeCallback :: proc(pc: c.int, cb: Signaling_State_Callback) -> c.int ---

	rtcSetLocalDescription :: proc(pc: c.int, type: cstring) -> c.int ---
	rtcSetLocalDescriptionEx :: proc(pc: c.int, type: cstring, init: ^Local_Description_Init) -> c.int ---
	rtcSetRemoteDescription :: proc(pc: c.int, sdp, type: cstring) -> c.int ---
	rtcAddRemoteCandidate :: proc(pc: c.int, cand, mid: cstring) -> c.int ---

	rtcGetLocalDescription :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetRemoteDescription :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetLocalDescriptionType :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetRemoteDescriptionType :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcCreateOffer :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcCreateAnswer :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetLocalAddress :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetRemoteAddress :: proc(pc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetSelectedCandidatePair :: proc(pc: c.int, local: [^]u8, localSize: c.int, remote: [^]u8, remoteSize: c.int) -> c.int ---
	rtcIsNegotiationNeeded :: proc(pc: c.int) -> bool ---

	rtcSetOpenCallback :: proc(id: c.int, cb: Open_Callback) -> c.int ---
	rtcSetClosedCallback :: proc(id: c.int, cb: Closed_Callback) -> c.int ---
	rtcSetErrorCallback :: proc(id: c.int, cb: Error_Callback) -> c.int ---
	rtcSetMessageCallback :: proc(id: c.int, cb: Message_Callback) -> c.int ---
	rtcSendMessage :: proc(id: c.int, data: [^]u8, size: c.int) -> c.int ---
	rtcClose :: proc(id: c.int) -> c.int ---
	rtcDelete :: proc(id: c.int) -> c.int ---
	rtcIsOpen :: proc(id: c.int) -> bool ---
	rtcIsClosed :: proc(id: c.int) -> bool ---
	rtcMaxMessageSize :: proc(id: c.int) -> c.int ---
	rtcGetBufferedAmount :: proc(id: c.int) -> c.int ---
	rtcSetBufferedAmountLowThreshold :: proc(id: c.int, amount: c.int) -> c.int ---
	rtcSetBufferedAmountLowCallback :: proc(id: c.int, cb: Buffered_Amount_Callback) -> c.int ---
	rtcGetAvailableAmount :: proc(id: c.int) -> c.int ---
	rtcSetAvailableCallback :: proc(id: c.int, cb: Available_Callback) -> c.int ---
	rtcReceiveMessage :: proc(id: c.int, buffer: [^]u8, size: ^c.int) -> c.int ---

	rtcSetDataChannelCallback :: proc(pc: c.int, cb: Data_Channel_Callback) -> c.int ---
	rtcCreateDataChannel :: proc(pc: c.int, label: cstring) -> c.int ---
	rtcCreateDataChannelEx :: proc(pc: c.int, label: cstring, init: ^Data_Channel_Init) -> c.int ---
	rtcDeleteDataChannel :: proc(dc: c.int) -> c.int ---
	rtcGetDataChannelStream :: proc(dc: c.int) -> c.int ---
	rtcGetDataChannelLabel :: proc(dc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetDataChannelProtocol :: proc(dc: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetDataChannelReliability :: proc(dc: c.int, reliability: ^Reliability) -> c.int ---

	rtcSetTrackCallback :: proc(pc: c.int, cb: Track_Callback) -> c.int ---
	rtcAddTrack :: proc(pc: c.int, mediaDescriptionSdp: cstring) -> c.int ---
	rtcAddTrackEx :: proc(pc: c.int, init: ^Track_Init) -> c.int ---
	rtcDeleteTrack :: proc(tr: c.int) -> c.int ---
	rtcGetTrackDescription :: proc(tr: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetTrackMid :: proc(tr: c.int, buffer: [^]u8, size: c.int) -> c.int ---
	rtcGetTrackDirection :: proc(tr: c.int, direction: ^Direction) -> c.int ---
	rtcGetTrackPayloadTypesForCodec :: proc(tr: c.int, codec: cstring, buffer: [^]c.int, size: c.int) -> c.int ---
	rtcRequestKeyframe :: proc(tr: c.int) -> c.int ---
	rtcRequestBitrate :: proc(tr: c.int, bitrate: c.uint) -> c.int ---
	rtcSetFrameCallback :: proc(tr: c.int, cb: Frame_Callback) -> c.int ---

	rtcSetH264Packetizer :: proc(tr: c.int, init: ^Packetizer_Init) -> c.int ---
	rtcSetH265Packetizer :: proc(tr: c.int, init: ^Packetizer_Init) -> c.int ---
	rtcSetOpusPacketizer :: proc(tr: c.int, init: ^Packetizer_Init) -> c.int ---
	rtcChainRtcpReceivingSession :: proc(tr: c.int) -> c.int ---
	rtcChainRtcpSrReporter :: proc(tr: c.int) -> c.int ---
	rtcChainRtcpNackResponder :: proc(tr: c.int, maxStoredPacketsCount: c.uint) -> c.int ---
	rtcChainPliHandler :: proc(tr: c.int, cb: Pli_Handler_Callback) -> c.int ---
	rtcChainRembHandler :: proc(tr: c.int, cb: Remb_Handler_Callback) -> c.int ---
	rtcTransformSecondsToTimestamp :: proc(id: c.int, seconds: f64, timestamp: ^u32) -> c.int ---
	rtcTransformTimestampToSeconds :: proc(id: c.int, timestamp: u32, seconds: ^f64) -> c.int ---
	rtcGetCurrentTrackTimestamp :: proc(id: c.int, timestamp: ^u32) -> c.int ---
	rtcSetTrackRtpTimestamp :: proc(id: c.int, timestamp: u32) -> c.int ---
	rtcGetLastTrackSenderReportTimestamp :: proc(id: c.int, timestamp: ^u32) -> c.int ---

	rtcSetThreadPoolSize :: proc(count: c.uint) -> c.int ---
	rtcSetSctpSettings :: proc(settings: ^Sctp_Settings) -> c.int ---
	rtcPreload :: proc() -> bool ---
	rtcCleanup :: proc() ---
}
