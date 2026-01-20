package main

import (
	"sync"
	"time"

	"github.com/hugolgst/rich-go/client"
)

const discordClientID = "1417754671895806062"

// DiscordRPC manages Discord Rich Presence
type DiscordRPC struct {
	mu             sync.Mutex
	connected      bool
	currentDetails string
	currentState   string
	startTime      time.Time
}

var discordRPC = &DiscordRPC{}

// DiscordActivity represents the activity to display
type DiscordActivity struct {
	Title  string `json:"title"`
	Artist string `json:"artist"`
}

// ConnectToDiscord initializes the Discord RPC connection
func ConnectToDiscord() error {
	discordRPC.mu.Lock()
	defer discordRPC.mu.Unlock()

	if discordRPC.connected {
		return nil
	}

	err := client.Login(discordClientID)
	if err != nil {
		return err
	}

	discordRPC.connected = true
	return nil
}

// SetDiscordActivity updates the Discord Rich Presence
func SetDiscordActivity(activity DiscordActivity) error {
	discordRPC.mu.Lock()
	defer discordRPC.mu.Unlock()

	if !discordRPC.connected {
		// Try to connect
		if err := client.Login(discordClientID); err != nil {
			return err
		}
		discordRPC.connected = true
	}

	// Truncate to Discord limits
	details := activity.Title
	if len(details) > 128 {
		details = details[:128]
	}
	state := "by " + activity.Artist
	if len(state) > 128 {
		state = state[:128]
	}

	// Skip if same as current
	if discordRPC.currentDetails == details && discordRPC.currentState == state {
		return nil
	}

	discordRPC.currentDetails = details
	discordRPC.currentState = state
	discordRPC.startTime = time.Now()

	err := client.SetActivity(client.Activity{
		Details:    details,
		State:      state,
		LargeImage: "ux_music_icon",
		LargeText:  "UX Music",
		Timestamps: &client.Timestamps{
			Start: &discordRPC.startTime,
		},
	})

	return err
}

// ClearDiscordActivity clears the Discord Rich Presence
func ClearDiscordActivity() error {
	discordRPC.mu.Lock()
	defer discordRPC.mu.Unlock()

	discordRPC.currentDetails = ""
	discordRPC.currentState = ""

	// rich-go doesn't have a clear function, so we logout and re-login is not ideal
	// For now, set an empty activity or just leave it
	// The activity will clear after a timeout anyway
	return nil
}

// DisconnectDiscord closes the Discord RPC connection
func DisconnectDiscord() {
	discordRPC.mu.Lock()
	defer discordRPC.mu.Unlock()

	if discordRPC.connected {
		client.Logout()
		discordRPC.connected = false
	}
}
