(function () {
  "use strict";

  window.doom = window.doom || {};

  var TARGET_FPS = 35;
  var FRAME_INTERVAL = 1000 / TARGET_FPS;
  var HEARTBEAT_INTERVAL = 30000;
  var snapshotEl = document.getElementById("snapshot");
  var fpsEl = document.getElementById("fps");
  var gameEl = document.getElementById("game");

  var lastTimestamp = 0;
  var frameCount = 0;
  var fpsTimerId = null;
  var heartbeatId = null;
  var active = false;
  var slot = null;

  function updateFpsMeter() {
    fpsEl.textContent = frameCount;
    frameCount = 0;
    if (active) fpsTimerId = setTimeout(updateFpsMeter, 1000);
  }

  function loadNextFrame() {
    if (!active) return;
    var now = performance.now();
    var elapsed = now - lastTimestamp;
    var delay = Math.max(0, FRAME_INTERVAL - elapsed);

    setTimeout(function () {
      if (!active) return;
      frameCount++;
      lastTimestamp = performance.now();
      snapshotEl.src = "/player/" + slot + "/screen/snapshot.jpg?" + lastTimestamp;
    }, delay);
  }

  function onFrameLoad() { loadNextFrame(); }
  function onFrameError() {
    if (active) setTimeout(loadNextFrame, 500);
  }

  function hideLoading() {
    gameEl.style.backgroundImage = "none";
    snapshotEl.removeEventListener("load", hideLoading);
  }

  function sendHeartbeat() {
    if (!active || !slot) return;
    fetch("/player/" + slot + "/heartbeat").catch(function () {});
  }

  window.doom.startFrameLoading = function (s) {
    slot = s;
    active = true;
    lastTimestamp = performance.now();
    frameCount = 0;

    snapshotEl.addEventListener("load", onFrameLoad);
    snapshotEl.addEventListener("error", onFrameError);
    snapshotEl.addEventListener("load", hideLoading);

    updateFpsMeter();
    snapshotEl.src = "/player/" + slot + "/screen/snapshot.jpg";

    heartbeatId = setInterval(sendHeartbeat, HEARTBEAT_INTERVAL);
  };

  window.doom.stopFrameLoading = function () {
    active = false;
    slot = null;
    snapshotEl.removeEventListener("load", onFrameLoad);
    snapshotEl.removeEventListener("error", onFrameError);
    snapshotEl.removeEventListener("load", hideLoading);
    snapshotEl.src = "";
    fpsEl.textContent = "0";
    gameEl.style.backgroundImage = "url('http-doom.png')";
    if (fpsTimerId) { clearTimeout(fpsTimerId); fpsTimerId = null; }
    if (heartbeatId) { clearInterval(heartbeatId); heartbeatId = null; }
  };
})();
