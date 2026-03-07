(function () {
  "use strict";

  window.doom = window.doom || {};

  var slot = null;

  function bindClick(id, pathFn) {
    document.getElementById(id).addEventListener("click", function () {
      if (slot) fetch(pathFn());
    });
  }

  window.doom.startSettings = function (s) {
    slot = s;
  };

  window.doom.stopSettings = function () {
    slot = null;
  };

  bindClick("resetBtn", function () { return "/player/" + slot + "/reset"; });
  bindClick("grayscaleBtn", function () { return "/player/" + slot + "/config/colorspace?Gray"; });
  bindClick("colorBtn", function () { return "/player/" + slot + "/config/colorspace?RGB"; });
  bindClick("quality15Btn", function () { return "/player/" + slot + "/config/quality?15"; });
  bindClick("quality25Btn", function () { return "/player/" + slot + "/config/quality?25"; });
  bindClick("quality50Btn", function () { return "/player/" + slot + "/config/quality?50"; });
  bindClick("quality75Btn", function () { return "/player/" + slot + "/config/quality?75"; });
  bindClick("quality100Btn", function () { return "/player/" + slot + "/config/quality?100"; });
})();
