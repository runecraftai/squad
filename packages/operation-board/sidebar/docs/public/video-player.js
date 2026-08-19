(() => {
  function initVideoPlayers() {
    const players = document.querySelectorAll("[data-video-player]");

    for (const player of players) {
      if (
        !(player instanceof HTMLElement) ||
        player.dataset.enhanced === "true"
      ) {
        continue;
      }

      const video = player.querySelector("video");
      const toggle = player.querySelector(".video-player-toggle");
      const label = player.querySelector(".video-player-state");
      if (
        !(video instanceof HTMLVideoElement) ||
        !(toggle instanceof HTMLButtonElement)
      ) {
        continue;
      }

      player.dataset.enhanced = "true";
      video.controls = false;

      const updateState = () => {
        const isPlaying = !video.paused && !video.ended;
        player.classList.toggle("is-playing", isPlaying);
        toggle.dataset.playing = String(isPlaying);
        toggle.setAttribute(
          "aria-label",
          isPlaying ? "Pause video" : "Play video",
        );
        if (label)
          label.textContent = isPlaying ? "Video playing" : "Video paused";
      };

      const togglePlayback = () => {
        if (video.paused || video.ended) {
          void video.play();
        } else {
          video.pause();
        }
      };

      toggle.addEventListener("click", togglePlayback);
      video.addEventListener("click", togglePlayback);
      video.addEventListener("play", updateState);
      video.addEventListener("pause", updateState);
      video.addEventListener("ended", updateState);
      updateState();
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initVideoPlayers, {
      once: true,
    });
  } else {
    initVideoPlayers();
  }
})();
