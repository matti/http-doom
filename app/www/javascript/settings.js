(function () {
  "use strict";

  function bindClick(id, url) {
    document.getElementById(id).addEventListener("click", function () {
      fetch(url);
    });
  }

  bindClick("resetBtn", "/reset");
  bindClick("grayscaleBtn", "/config/colorspace?Gray");
  bindClick("colorBtn", "/config/colorspace?RGB");
  bindClick("quality15Btn", "/config/quality?15");
  bindClick("quality25Btn", "/config/quality?25");
  bindClick("quality50Btn", "/config/quality?50");
  bindClick("quality75Btn", "/config/quality?75");
  bindClick("quality100Btn", "/config/quality?100");
})();
