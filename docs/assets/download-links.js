// Per-OS download links. The static button hrefs use
// /releases/latest/download/<asset>, which 404s when the newest release is
// single-OS (e.g. a Windows-only release ships no .dmg). Rewrite each button
// to the newest release that actually contains that OS's asset; on any
// failure the static hrefs stay as the fallback.
(function () {
  fetch("https://api.github.com/repos/LimFull/pokemon-mouse-follower/releases?per_page=20")
    .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error("http " + r.status)); })
    .then(function (releases) {
      // Releases arrive newest-first; return the first published one whose
      // asset list satisfies `test`.
      function latestAsset(test) {
        for (var i = 0; i < releases.length; i++) {
          var rel = releases[i];
          if (rel.draft || rel.prerelease) continue;
          var assets = rel.assets || [];
          for (var j = 0; j < assets.length; j++) {
            if (test(assets[j].name)) return assets[j].browser_download_url;
          }
        }
        return null;
      }
      function retarget(selector, url) {
        if (!url) return;
        document.querySelectorAll(selector).forEach(function (a) { a.href = url; });
      }
      retarget('a[href$="/PokemonMouseFollower.dmg"]',
               latestAsset(function (n) { return n === "PokemonMouseFollower.dmg"; })
               || latestAsset(function (n) { return /\.dmg$/.test(n); }));
      retarget('a[href$="/PokemonMouseFollower-Setup.exe"]',
               latestAsset(function (n) { return /-Setup\.exe$/.test(n); }));
    })
    .catch(function () { /* keep the static latest/download links */ });
})();
