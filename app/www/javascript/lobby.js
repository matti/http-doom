(function () {
  "use strict";

  window.doom = window.doom || {};
  window.doom.slot = null;

  var lobbyEl = document.getElementById("lobby");
  var gameEl = document.getElementById("game");
  var slotsEl = document.getElementById("slots");
  var joinBtn = document.getElementById("joinBtn");
  var statusEl = document.getElementById("lobbyStatus");
  var slotNumEl = document.getElementById("slotNum");
  var leaveBtn = document.getElementById("leaveBtn");

  var statusPollId = null;

  // Poll /status and update slot indicators
  function pollStatus() {
    fetch("/status")
      .then(function (r) { return r.json(); })
      .then(function (data) {
        var html = "";
        var freeCount = 0;
        for (var i = 1; i <= data.max_slots; i++) {
          var s = data.slots[String(i)];
          var cls = s && s.active ? "taken" : "free";
          if (!s || !s.active) freeCount++;
          html += '<span class="slot-indicator ' + cls + '" title="Slot ' + i + '"></span>';
        }
        slotsEl.innerHTML = html;
        statusEl.textContent = freeCount + "/" + data.max_slots + " slots free";
        joinBtn.disabled = freeCount === 0;
      })
      .catch(function () {
        statusEl.textContent = "connecting...";
      });
  }

  function startLobbyPolling() {
    pollStatus();
    statusPollId = setInterval(pollStatus, 2000);
  }

  function stopLobbyPolling() {
    if (statusPollId) {
      clearInterval(statusPollId);
      statusPollId = null;
    }
  }

  // Join a game
  joinBtn.addEventListener("click", function () {
    joinBtn.disabled = true;
    statusEl.textContent = "Joining...";

    fetch("/join")
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.error) {
          statusEl.textContent = data.error;
          joinBtn.disabled = false;
          return;
        }

        window.doom.slot = data.slot;
        slotNumEl.textContent = data.slot;

        // Switch to game view
        stopLobbyPolling();
        lobbyEl.style.display = "none";
        gameEl.style.display = "block";

        // Initialize game modules
        if (window.doom.startFrameLoading) window.doom.startFrameLoading(data.slot);
        if (window.doom.startKeyCapture) window.doom.startKeyCapture(data.slot);
        if (window.doom.startSettings) window.doom.startSettings(data.slot);
      })
      .catch(function () {
        statusEl.textContent = "Failed to join";
        joinBtn.disabled = false;
      });
  });

  // Leave game
  function leaveGame() {
    var slot = window.doom.slot;
    if (!slot) return;

    // Stop game modules
    if (window.doom.stopFrameLoading) window.doom.stopFrameLoading();
    if (window.doom.stopKeyCapture) window.doom.stopKeyCapture();
    if (window.doom.stopSettings) window.doom.stopSettings();

    window.doom.slot = null;

    // Switch to lobby view
    gameEl.style.display = "none";
    lobbyEl.style.display = "flex";
    startLobbyPolling();

    fetch("/leave/" + slot).catch(function () {});
  }

  leaveBtn.addEventListener("click", leaveGame);

  // Leave on tab close
  window.addEventListener("beforeunload", function () {
    if (window.doom.slot) {
      navigator.sendBeacon("/leave/" + window.doom.slot);
    }
  });

  // Start lobby
  startLobbyPolling();
})();
