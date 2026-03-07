(function () {
  "use strict";

  const TARGET_FPS = 35;
  const FRAME_INTERVAL = 1000 / TARGET_FPS;
  const snapshotEl = document.getElementById("snapshot");
  const fpsEl = document.getElementById("fps");

  let lastTimestamp = performance.now();
  let frameCount = 0;

  // FPS counter — updates display every second
  function updateFpsMeter() {
    fpsEl.textContent = frameCount;
    frameCount = 0;
    setTimeout(updateFpsMeter, 1000);
  }
  updateFpsMeter();

  // Load the next frame, pacing to target FPS
  function loadNextFrame() {
    const now = performance.now();
    const elapsed = now - lastTimestamp;
    const delay = Math.max(0, FRAME_INTERVAL - elapsed);

    setTimeout(function () {
      frameCount++;
      lastTimestamp = performance.now();
      snapshotEl.src = "screen/snapshot.jpg?" + lastTimestamp;
    }, delay);
  }

  snapshotEl.addEventListener("load", loadNextFrame);
  snapshotEl.addEventListener("error", loadNextFrame);

  // Hide loading background on first successful frame
  function hideLoading() {
    document.body.style.backgroundImage = "none";
    snapshotEl.removeEventListener("load", hideLoading);
  }
  snapshotEl.addEventListener("load", hideLoading);

  // Kick off first frame load
  snapshotEl.src = "screen/snapshot.jpg";
})();
