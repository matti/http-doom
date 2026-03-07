(function () {
  "use strict";

  window.doom = window.doom || {};

  var KEY_MAP = {
    " ": "space",
    "Enter": "Return",
    "ControlLeft": "Control",
    "ArrowUp": "Up",
    "ArrowDown": "Down",
    "ArrowLeft": "Left",
    "ArrowRight": "Right",
  };

  var IGNORED_KEYS = { "Tab": true, "Meta": true };
  var pressedKeys = {};
  var active = false;
  var slot = null;

  function mapKey(e) {
    return KEY_MAP[e.key] || e.key;
  }

  function performKey(operation, key) {
    if (!active || !slot) return;
    if (IGNORED_KEYS[key]) return;
    if (operation === "down" && pressedKeys[key]) return;
    if (operation === "down") pressedKeys[key] = true;

    fetch("/player/" + slot + "/key/" + operation + "/" + key)
      .then(function () {
        if (operation === "up") pressedKeys[key] = false;
      })
      .catch(function () {
        setTimeout(function () { performKey(operation, key); }, 10);
      });
  }

  function onKeyDown(e) { performKey("down", mapKey(e)); }
  function onKeyUp(e) { performKey("up", mapKey(e)); }

  function onVisibilityChange() {
    Object.keys(pressedKeys)
      .filter(function (k) { return pressedKeys[k]; })
      .forEach(function (k) { performKey("up", k); });
  }

  function onMouseMove(e) { e.preventDefault(); }
  function onDragStart(e) { e.preventDefault(); }

  window.doom.startKeyCapture = function (s) {
    slot = s;
    active = true;
    pressedKeys = {};
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("keyup", onKeyUp);
    document.addEventListener("visibilitychange", onVisibilityChange);
    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("dragstart", onDragStart);
  };

  window.doom.stopKeyCapture = function () {
    // Release all held keys
    onVisibilityChange();
    active = false;
    slot = null;
    document.removeEventListener("keydown", onKeyDown);
    document.removeEventListener("keyup", onKeyUp);
    document.removeEventListener("visibilitychange", onVisibilityChange);
    document.removeEventListener("mousemove", onMouseMove);
    document.removeEventListener("dragstart", onDragStart);
  };
})();
