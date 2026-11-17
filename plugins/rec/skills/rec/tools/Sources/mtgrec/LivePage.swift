import Foundation

/// 회의 중에 보는 페이지. SwiftPM 리소스로 두지 않고 문자열로 박아 넣는다.
/// 빌드 산출물 중 바이너리 하나만 `~/.claude/bin` 으로 복사되므로 번들 리소스는 찾지 못한다.
let livePageHTML = #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>mtgrec live</title>
<style>
  :root {
    --bg: #f7f7f5; --panel: #ffffff; --line: #e2e0da; --ink: #23211d;
    --muted: #7d7a72; --me: #1f6f5c; --them: #3a5ba8; --warn: #a4522c;
    --warn-bg: #fdf1e8; --accent: #23211d;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #171614; --panel: #201f1c; --line: #34322d; --ink: #e8e6e0;
      --muted: #918d84; --me: #6cc0a5; --them: #8fa9e0; --warn: #e0a077;
      --warn-bg: #2e241c; --accent: #e8e6e0;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 14px/1.65 -apple-system, "SF Pro Text", "Apple SD Gothic Neo", "Noto Sans KR", sans-serif;
    height: 100vh; display: flex; flex-direction: column;
  }
  header {
    display: flex; align-items: center; gap: 16px; flex-wrap: wrap;
    padding: 10px 18px; border-bottom: 1px solid var(--line); background: var(--panel);
  }
  h1 { font-size: 15px; font-weight: 600; margin: 0; }
  .clock { font-variant-numeric: tabular-nums; color: var(--muted); font-size: 13px; }
  .levels { display: flex; gap: 12px; margin-left: auto; align-items: center; }
  .lvl { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--line); transition: background .2s; }
  .dot.live { background: var(--me); }
  .dot.them.live { background: var(--them); }
  .dot.dead { background: var(--warn); }
  button {
    font: inherit; font-size: 13px; padding: 5px 12px; border-radius: 6px;
    border: 1px solid var(--line); background: var(--panel); color: var(--ink); cursor: pointer;
  }
  button:hover:not(:disabled) { border-color: var(--accent); }
  button:disabled { opacity: .45; cursor: default; }
  button.danger { color: var(--warn); }
  #banners { padding: 0 18px; }
  .banner {
    margin-top: 10px; padding: 9px 12px; border-radius: 6px; font-size: 13px;
    background: var(--warn-bg); color: var(--warn); border: 1px solid currentColor;
  }
  main { flex: 1; display: grid; grid-template-columns: 1fr 1fr; gap: 1px;
         background: var(--line); min-height: 0; margin-top: 10px; border-top: 1px solid var(--line); }
  @media (max-width: 900px) { main { grid-template-columns: 1fr; } }
  section { background: var(--bg); min-height: 0; display: flex; flex-direction: column; }
  .head {
    padding: 9px 18px; font-size: 12px; font-weight: 600; color: var(--muted);
    letter-spacing: .04em; display: flex; align-items: center; gap: 10px;
    border-bottom: 1px solid var(--line);
  }
  .head label { font-weight: 400; margin-left: auto; display: flex; align-items: center; gap: 5px; }
  .scroll { overflow-y: auto; padding: 14px 18px 40px; flex: 1; }
  .turn { margin-bottom: 14px; }
  .who { font-size: 12px; font-weight: 600; margin-bottom: 2px; }
  .who .at { font-weight: 400; color: var(--muted); font-variant-numeric: tabular-nums; margin-left: 6px; }
  .mic .who { color: var(--me); }
  .sys .who { color: var(--them); }
  .say { white-space: pre-wrap; word-break: break-word; }
  .partial { color: var(--muted); font-style: italic; }
  .empty { color: var(--muted); }
  .card {
    background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
    padding: 12px 14px; margin-bottom: 10px;
  }
  .card h3 { margin: 0 0 8px; font-size: 14px; font-weight: 600; }
  .card h3 .rank { color: var(--muted); font-weight: 400; margin-right: 6px; }
  .field { display: grid; grid-template-columns: 42px 1fr; gap: 8px; margin-top: 3px; }
  .field b { font-weight: 600; font-size: 12px; color: var(--muted); }
  .sub { font-size: 12px; font-weight: 600; color: var(--muted); letter-spacing: .04em;
         margin: 18px 0 8px; }
  .sub:first-child { margin-top: 0; }
  ul { margin: 0; padding-left: 18px; }
  li { margin-bottom: 4px; }
  footer { padding: 7px 18px; border-top: 1px solid var(--line); background: var(--panel);
           font-size: 12px; color: var(--muted); display: flex; gap: 14px; flex-wrap: wrap; }
  .tracks { border-collapse: collapse; font-size: 13px; width: 100%; margin-top: 6px; }
  .tracks th, .tracks td { text-align: left; padding: 4px 10px 4px 0; border-bottom: 1px solid var(--line); }
  .tracks th { color: var(--muted); font-weight: 600; font-size: 12px; }
</style>
</head>
<body>
<header>
  <h1 id="title">…</h1>
  <span class="clock" id="clock">0:00</span>
  <div class="levels">
    <span class="lvl"><span class="dot" id="dot-mic"></span>나</span>
    <span class="lvl"><span class="dot them" id="dot-sys"></span>상대</span>
    <button id="btn-sum">지금 요약</button>
    <button id="btn-stop" class="danger">녹음 종료</button>
  </div>
</header>

<div id="banners"></div>

<main>
  <section>
    <div class="head">실시간 전사
      <label><input type="checkbox" id="stick" checked> 맨 아래 고정</label>
    </div>
    <div class="scroll" id="transcript"><p class="empty">아직 인식된 발화가 없습니다.</p></div>
  </section>
  <section>
    <div class="head">지금까지의 논의 <span id="notes-at" style="font-weight:400"></span></div>
    <div class="scroll" id="notes"><p class="empty">발화가 쌓이면 논의 묶음이 여기 나타납니다.</p></div>
  </section>
</main>

<footer>
  <span>이 페이지의 전사와 요약은 실시간 미리보기입니다. 정본은 녹음 종료 후 <code>transcript.md</code>.</span>
  <span id="conn" style="margin-left:auto"></span>
</footer>

<script>
(function () {
  var token = new URLSearchParams(location.search).get("t") || "";
  var state = { segments: [], volatile: [], notes: null, startedAt: null,
                recording: true, finished: null, micOnly: false };
  var warnings = {};

  var $ = function (id) { return document.getElementById(id); };
  var esc = function (s) {
    return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  };
  var hhmmss = function (s) {
    s = Math.max(0, Math.floor(s || 0));
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    var pad = function (n) { return (n < 10 ? "0" : "") + n; };
    return h > 0 ? h + ":" + pad(m) + ":" + pad(x) : m + ":" + pad(x);
  };

  // 같은 화자가 이어 말한 조각은 한 덩어리로 묶어 그린다. 문장마다 줄을 나누면 읽을 수가 없다.
  function blocks(segments) {
    var out = [];
    segments.forEach(function (s) {
      var last = out[out.length - 1];
      if (last && last.track === s.track && s.start - last.end <= 2.5 && s.end - last.start <= 60) {
        last.end = s.end;
        last.text += " " + s.text;
      } else {
        out.push({ track: s.track, speaker: s.speaker, start: s.start, end: s.end, text: s.text });
      }
    });
    return out;
  }

  function renderTranscript() {
    var box = $("transcript");
    var atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
    var html = "";
    blocks(state.segments).forEach(function (b) {
      html += '<div class="turn ' + esc(b.track) + '"><div class="who">' + esc(b.speaker) +
              '<span class="at">' + hhmmss(b.start) + "</span></div>" +
              '<div class="say">' + esc(b.text) + "</div></div>";
    });
    state.volatile.forEach(function (v) {
      if (!v.text) return;
      html += '<div class="turn ' + esc(v.track) + '"><div class="who">' + esc(v.speaker) +
              '<span class="at">인식 중</span></div>' +
              '<div class="say partial">' + esc(v.text) + "</div></div>";
    });
    if (!html) html = '<p class="empty">아직 인식된 발화가 없습니다.</p>';
    if (state.finished) {
      var rows = state.finished.tracks.map(function (t) {
        return "<tr><td>" + esc(t.speaker) + " (" + esc(t.name) + ")</td><td>" +
               hhmmss(t.seconds) + "</td><td>peak " + (t.peak || 0).toFixed(3) +
               (t.peak < 0.01 ? " (무음에 가까움)" : "") + "</td></tr>";
      }).join("");
      html = '<div class="card"><h3>녹음 종료</h3><table class="tracks">' +
             "<tr><th>트랙</th><th>길이</th><th>레벨</th></tr>" + rows + "</table>" +
             (state.finished.note ? "<p>" + esc(state.finished.note) + "</p>" : "") +
             "<p>터미널에서 <code>/rec stop</code> 이 전사와 요약을 이어서 합니다.</p></div>" + html;
    }
    box.innerHTML = html;
    if ($("stick").checked && atBottom) box.scrollTop = box.scrollHeight;
  }

  function renderNotes() {
    var n = state.notes;
    var box = $("notes");
    if (!n || (!n.headline.length && !n.topics.length && !n.actions.length)) {
      box.innerHTML = n && n.running
        ? '<p class="empty">요약하는 중…</p>'
        : '<p class="empty">발화가 쌓이면 논의 묶음이 여기 나타납니다.</p>';
      $("notes-at").textContent = "";
      return;
    }
    var html = "";
    if (n.headline.length) {
      html += '<div class="sub">지금까지의 결론</div><ul>' +
              n.headline.map(function (h) { return "<li>" + esc(h) + "</li>"; }).join("") + "</ul>";
    }
    if (n.topics.length) {
      html += '<div class="sub">논의 안건</div>';
      n.topics.slice().sort(function (a, b) {
        return (a.importance || 9) - (b.importance || 9);
      }).forEach(function (t, i) {
        html += '<div class="card"><h3><span class="rank">' + (i + 1) + ".</span>" + esc(t.title) + "</h3>";
        if (t.background) html += '<div class="field"><b>배경</b><span>' + esc(t.background) + "</span></div>";
        if (t.content) html += '<div class="field"><b>내용</b><span>' + esc(t.content) + "</span></div>";
        if (t.conclusion) html += '<div class="field"><b>결론</b><span>' + esc(t.conclusion) + "</span></div>";
        html += "</div>";
      });
    }
    if (n.actions.length) {
      html += '<div class="sub">액션 플랜</div><ul>' +
              n.actions.map(function (a) { return "<li>" + esc(a) + "</li>"; }).join("") + "</ul>";
    }
    box.innerHTML = html;
    $("notes-at").textContent = n.running ? "갱신 중…"
      : (n.updatedAt ? new Date(n.updatedAt).toTimeString().slice(0, 5) + " 기준" : "");
    banner("summary", n.lastError ? "요약 실패: " + n.lastError + " (직전 노트를 그대로 둡니다)" : null);
  }

  function banner(key, text) {
    if (text) warnings[key] = text; else delete warnings[key];
    $("banners").innerHTML = Object.keys(warnings).map(function (k) {
      return '<div class="banner">' + esc(warnings[k]) + "</div>";
    }).join("");
  }

  function renderLevels(levels) {
    (levels || []).forEach(function (l) {
      var dot = $("dot-" + l.track);
      if (!dot) return;
      dot.classList.toggle("live", l.peak >= 0.01);
      dot.classList.toggle("dead", l.silentSeconds >= 60);
    });
    var sys = (levels || []).filter(function (l) { return l.track === "sys"; })[0];
    banner("sys", sys && sys.silentSeconds >= 60 && state.recording
      ? "상대 트랙이 " + Math.floor(sys.silentSeconds) + "초째 무음입니다. 회의 앱이 이 맥에 붙어 있는지, 소리가 다른 출력 장치로 나가고 있지 않은지 확인하십시오."
      : null);
  }

  function tick() {
    if (!state.startedAt) return;
    var end = state.recording ? Date.now() : (state.stoppedAt || Date.now());
    $("clock").textContent = hhmmss((end - state.startedAt) / 1000);
  }
  setInterval(tick, 1000);

  function apply(name, d) {
    if (name === "snapshot") {
      state.segments = d.segments || [];
      state.volatile = d.volatile || [];
      state.notes = d.notes || null;
      state.recording = d.recording;
      state.finished = d.finished || null;
      state.micOnly = d.micOnly;
      state.startedAt = Date.parse(d.startedAt);
      $("title").textContent = d.title;
      document.title = d.title + " (mtgrec)";
      if (d.micOnly) banner("mic-only", "마이크만 녹음 중입니다. 화자 구분이 없습니다.");
      (d.warnings || []).forEach(function (w) { banner(w.key, w.text); });
      renderLevels(d.levels);
      renderTranscript(); renderNotes(); tick();
      $("btn-stop").disabled = !d.recording;
      $("btn-sum").disabled = !d.recording;
    } else if (name === "segments") {
      state.segments = state.segments.concat(d);
      renderTranscript();
    } else if (name === "volatile") {
      state.volatile = d;
      renderTranscript();
    } else if (name === "levels") {
      renderLevels(d);
    } else if (name === "warning") {
      banner(d.key, d.text);
    } else if (name === "notes") {
      state.notes = d;
      renderNotes();
    } else if (name === "status") {
      state.recording = d.recording;
      state.finished = d.finished || null;
      state.stoppedAt = Date.now();
      state.volatile = [];
      $("btn-stop").disabled = true;
      $("btn-sum").disabled = true;
      banner("sys", null);
      renderTranscript();
    }
  }

  function connect() {
    var es = new EventSource("/events?t=" + encodeURIComponent(token));
    ["snapshot", "segments", "volatile", "levels", "notes", "status", "warning"].forEach(function (name) {
      es.addEventListener(name, function (e) {
        try { apply(name, JSON.parse(e.data)); } catch (err) { console.error(name, err); }
      });
    });
    es.onopen = function () { $("conn").textContent = ""; };
    es.onerror = function () {
      $("conn").textContent = state.recording ? "연결 끊김. 다시 붙는 중…" : "종료됨";
    };
  }

  function post(path, button, label) {
    button.disabled = true;
    var previous = button.textContent;
    button.textContent = label;
    fetch(path + "?t=" + encodeURIComponent(token), { method: "POST" })
      .catch(function () {})
      .then(function () {
        setTimeout(function () {
          button.textContent = previous;
          if (state.recording) button.disabled = false;
        }, 1500);
      });
  }

  $("btn-sum").onclick = function () { post("/summarize", this, "요약 중…"); };
  $("btn-stop").onclick = function () { post("/stop", this, "종료 중…"); };

  if (!token) {
    banner("token", "URL 에 토큰이 없습니다. mtgrec 이 출력한 주소를 그대로 여십시오.");
  } else {
    connect();
  }
})();
</script>
</body>
</html>
"""#
