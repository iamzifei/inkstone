/* Inkstone — inkslab.app
 *
 * Four small jobs, none of which the page needs in order to be readable. Every
 * one of them starts from the finished page and adds to it, rather than hiding
 * the page and revealing it later: with this file blocked the visitor still gets
 * all the text, all the pictures and the video's poster frame.
 */
(function () {
  "use strict";

  var reduced = false;
  try {
    reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch (e) {}

  /* 1. The rule under the sticky bar, once the page is over content.
   *    Read inside rAF because a scroll handler that measures synchronously is
   *    the classic way to make a page that scrolls smoothly stutter. */
  var nav = document.getElementById("nav");
  if (nav) {
    var ticking = false;
    var sync = function () {
      if (window.scrollY > 8) nav.setAttribute("data-scrolled", "");
      else nav.removeAttribute("data-scrolled");
      ticking = false;
    };
    window.addEventListener("scroll", function () {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(sync);
    }, { passive: true });
    sync();
  }

  /* 2. Reveal on arrival.
   *    The `data-reveal` flag goes on <html> here rather than being written into
   *    the HTML, so the hidden state only exists once something is able to undo
   *    it. Without JavaScript, or with an observer that never fires, .reveal is
   *    an inert class name on visible content. */
  var targets = document.querySelectorAll(".reveal");
  if (!reduced && targets.length && "IntersectionObserver" in window) {
    document.documentElement.setAttribute("data-reveal", "");
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.setAttribute("data-shown", "");
        io.unobserve(entry.target);   // arriving is a one-way trip
      });
    }, { rootMargin: "0px 0px -12% 0px", threshold: 0.08 });
    Array.prototype.forEach.call(targets, function (el) { io.observe(el); });

    // A page that cannot scroll can never bring anything further into view, so
    // the negative rootMargin above would leave whatever sits in the bottom 12%
    // hidden for good. That is not hypothetical: on a tall enough window the
    // closing line and its buttons never appeared at all.
    if (document.documentElement.scrollHeight <= window.innerHeight + 4) {
      Array.prototype.forEach.call(targets, function (el) {
        el.setAttribute("data-shown", "");
      });
    }
  }

  /* 3. The demo.
   *    It autoplays, because a silent hero loop waiting for a click is a hero
   *    loop nobody watches. Someone who has asked their system for less motion
   *    has already answered that question, so they get the poster frame and a
   *    control bar instead of a decision made for them. There is no CSS-only way
   *    to do this — prefers-reduced-motion cannot suppress an autoplay attribute.
   *
   *    The fade-in waits for real frames rather than for `loadeddata`, so the
   *    video never appears as a black rectangle on a slow connection. */
  var film = document.querySelector(".film-frame");
  if (film) {
    if (reduced) {
      film.autoplay = false;
      film.loop = false;
      film.removeAttribute("autoplay");
      film.setAttribute("controls", "");
      try { film.pause(); } catch (e) {}
      film.setAttribute("data-ready", "");
    } else {
      var ready = function () { film.setAttribute("data-ready", ""); };
      if (film.readyState >= 3) ready();
      else film.addEventListener("canplay", ready, { once: true });
      // A browser may refuse to autoplay even a muted video. Rather than leave a
      // frozen poster with no way in, hand the reader the controls.
      var play = film.play();
      if (play && typeof play.catch === "function") {
        play.catch(function () {
          film.setAttribute("controls", "");
          ready();
        });
      }
      // Off-screen playback is decode work nobody is watching. Pausing it back
      // costs nothing and is most of this page's battery cost on a laptop.
      if ("IntersectionObserver" in window) {
        new IntersectionObserver(function (entries) {
          entries.forEach(function (entry) {
            if (entry.isIntersecting) { film.play().catch(function () {}); }
            else { film.pause(); }
          });
        }, { threshold: 0.15 }).observe(film);
      }
    }
  }

  /* 4. Remember a deliberate language choice.
   *    The redirect in <head> only runs when this key is absent, so writing it
   *    here is what stops the site bouncing someone who picked English on a
   *    Chinese-language machine straight back to Chinese. */
  Array.prototype.forEach.call(document.querySelectorAll("a.lang"), function (a) {
    a.addEventListener("click", function () {
      try { localStorage.setItem("inkstone-lang", a.getAttribute("data-lang")); } catch (e) {}
    });
  });
})();
