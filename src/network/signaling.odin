package network

// JSON messages exchanged on ws://<host>/signal. Video does not go over this socket.

Signal_Message :: struct {
	type:      string `json:"type"`,                          // "offer" | "answer" | "candidate" | "error" | "bye" | "keyframe" | "viewer-ready"
	sdp:       string `json:"sdp,omitempty"`,
	candidate: string `json:"candidate,omitempty"`,
	mid:       string `json:"sdpMid,omitempty"`,
	message:   string `json:"message,omitempty"`,
}
