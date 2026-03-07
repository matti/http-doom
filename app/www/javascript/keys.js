(function () {
  "use strict";

  const KEY_MAP = {
    " ": "space",
    "Enter": "Return",
    "ControlLeft": "Control",
    "ArrowUp": "Up",
    "ArrowDown": "Down",
    "ArrowLeft": "Left",
    "ArrowRight": "Right",
  };

  const IGNORED_KEYS = new Set(["Tab", "Meta"]);
  const pressedKeys = {};

  function mapKey(e) {
    return KEY_MAP[e.key] || e.key;
  }

  function performKey(operation, key) {
    if (IGNORED_KEYS.has(key)) return;

    // Prevent duplicate keydown events
    if (operation === "down" && pressedKeys[key]) return;

    // Mark as pressed immediately (optimistic)
    if (operation === "down") {
      pressedKeys[key] = true;
    }

    fetch("/key/" + operation + "/" + key)
      .then(function () {
        if (operation === "up") {
          pressedKeys[key] = false;
        }
      })
      .catch(function () {
        // Retry once on failure
        setTimeout(function () {
          performKey(operation, key);
        }, 10);
      });
  }

  // Release all keys when tab/window loses focus
  document.addEventListener("visibilitychange", function () {
    Object.keys(pressedKeys)
      .filter(function (key) { return pressedKeys[key]; })
      .forEach(function (key) { performKey("up", key); });
  });

  document.addEventListener("keydown", function (e) {
    performKey("down", mapKey(e));
  });

  document.addEventListener("keyup", function (e) {
    performKey("up", mapKey(e));
  });

  // Prevent drag/selection interference with gameplay
  document.addEventListener("mousemove", function (e) { e.preventDefault(); });
  document.addEventListener("dragstart", function (e) { e.preventDefault(); });
})();
