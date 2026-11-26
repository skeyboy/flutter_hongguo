(() => {
  const paths = {
    search:
      '<circle cx="11" cy="11" r="7"></circle><path d="m20 20-3.8-3.8"></path>',
    compass:
      '<circle cx="12" cy="12" r="9"></circle><path d="m15.5 8.5-2.2 4.8-4.8 2.2 2.2-4.8 4.8-2.2Z"></path>',
    grid: '<rect x="4" y="4" width="6" height="6" rx="1"></rect><rect x="14" y="4" width="6" height="6" rx="1"></rect><rect x="4" y="14" width="6" height="6" rx="1"></rect><rect x="14" y="14" width="6" height="6" rx="1"></rect>',
    rank: '<path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0V4Z"></path><path d="M7 6H4v2a4 4 0 0 0 4 4M17 6h3v2a4 4 0 0 1-4 4"></path>',
    user: '<circle cx="12" cy="8" r="4"></circle><path d="M4 21a8 8 0 0 1 16 0"></path>',
    settings:
      '<path d="m9.5 4 .7-2h3.6l.7 2 2.1 1.2 2-.5 1.8 3.1-1.5 1.5v2.4l1.5 1.5-1.8 3.1-2-.5-2.1 1.2-.7 2h-3.6l-.7-2-2.1-1.2-2 .5-1.8-3.1 1.5-1.5V9.3L3.7 7.8l1.8-3.1 2 .5L9.5 4Z"></path><circle cx="12" cy="11" r="3"></circle>',
    play: '<path d="m8 5 11 7-11 7V5Z" fill="currentColor" stroke="none"></path>',
    pause: '<path d="M8 5v14M16 5v14" stroke-width="4"></path>',
    back: '<path d="m15 18-6-6 6-6"></path>',
    forward: '<path d="m9 18 6-6-6-6"></path>',
    close: '<path d="m6 6 12 12M18 6 6 18"></path>',
    download: '<path d="M12 3v12m-5-5 5 5 5-5M4 20h16"></path>',
    heart: '<path d="M20.8 5.8a5.5 5.5 0 0 0-7.8 0L12 6.9l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 22l8.8-8.4a5.5 5.5 0 0 0 0-7.8Z"></path>',
    bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9ZM10 21h4"></path>',
    more: '<circle cx="5" cy="12" r="1.2" fill="currentColor" stroke="none"></circle><circle cx="12" cy="12" r="1.2" fill="currentColor" stroke="none"></circle><circle cx="19" cy="12" r="1.2" fill="currentColor" stroke="none"></circle>',
    check: '<path d="m5 12 4 4L19 6"></path>',
    chevronDown: '<path d="m6 9 6 6 6-6"></path>',
    volume: '<path d="M11 4 6 8H3v8h3l5 4V4Z"></path><path d="M15 8a6 6 0 0 1 0 8M18 5a10 10 0 0 1 0 14"></path>',
    mute: '<path d="M11 4 6 8H3v8h3l5 4V4Z"></path><path d="m16 9 5 6M21 9l-5 6"></path>',
    fullscreen: '<path d="M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5"></path>',
    episodes:
      '<rect x="3" y="5" width="18" height="14" rx="2"></rect><path d="M8 5v14M12 9h5M12 13h5"></path>',
    speed: '<path d="M5 18a8 8 0 1 1 14 0"></path><path d="m12 14 4-5"></path><circle cx="12" cy="14" r="1.5"></circle>',
    cast: '<path d="M4 18a3 3 0 0 1 3-3h10a3 3 0 0 1 3 3M4 21a7 7 0 0 1 7-7M4 15a11 11 0 0 1 11-11"></path><rect x="2" y="4" width="20" height="12" rx="2"></rect>',
    pip: '<rect x="3" y="5" width="18" height="14" rx="2"></rect><rect x="12" y="12" width="6" height="4" rx="1" fill="currentColor"></rect>',
    keyboard: '<rect x="2" y="6" width="20" height="12" rx="2"></rect><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"></path>',
    sun: '<circle cx="12" cy="12" r="4"></circle><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"></path>',
    moon: '<path d="M20 15.5A8.5 8.5 0 0 1 8.5 4 8.5 8.5 0 1 0 20 15.5Z"></path>',
    history: '<path d="M3 12a9 9 0 1 0 3-6.7L3 8"></path><path d="M3 3v5h5M12 7v5l3 2"></path>',
    spark: '<path d="m12 3 2.2 5.8L20 11l-5.8 2.2L12 19l-2.2-5.8L4 11l5.8-2.2L12 3Z"></path>',
    filter: '<path d="M4 7h16M7 12h10M10 17h4"></path>',
    sort: '<path d="M8 4v16m-4-4 4 4 4-4M16 20V4m-4 4 4-4 4 4"></path>',
    rotate: '<path d="M20 7v5h-5M4 17v-5h5"></path><path d="M6.1 8a7 7 0 0 1 11.5-2L20 8M4 16l2.4 2A7 7 0 0 0 17.9 16"></path>',
    save: '<path d="M5 3h12l4 4v14H3V3h2Z"></path><path d="M7 3v6h10V3M7 21v-8h10v8"></path>',
    info: '<circle cx="12" cy="12" r="9"></circle><path d="M12 11v6M12 7h.01"></path>',
  };

  function icon(name, className = "") {
    return `<svg class="icon ${className}" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.info}</svg>`;
  }

  function hydrateIcons(root = document) {
    root.querySelectorAll("[data-icon]").forEach((element) => {
      element.innerHTML = icon(element.dataset.icon);
    });
  }

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function fitFrame(frame, wrapper, options = {}) {
    const maxWidth = options.maxWidth || window.innerWidth - 48;
    const maxHeight = options.maxHeight || window.innerHeight - 106;
    const scale = Math.min(
      maxWidth / frame.offsetWidth,
      maxHeight / frame.offsetHeight,
      1,
    );
    frame.style.transform = `scale(${scale})`;
    wrapper.style.width = `${frame.offsetWidth * scale}px`;
    wrapper.style.height = `${frame.offsetHeight * scale}px`;
    return scale;
  }

  function project(velocity, decelerationRate = 0.998) {
    return (velocity / 1000) * decelerationRate / (1 - decelerationRate);
  }

  function spring({
    from,
    to,
    velocity = 0,
    damping = 1,
    response = 0.32,
    onUpdate,
    onComplete,
  }) {
    let value = from;
    let speed = velocity;
    let previous = performance.now();
    let frame = 0;
    let cancelled = false;
    const omega = (2 * Math.PI) / response;

    function tick(now) {
      if (cancelled) return;
      const dt = clamp((now - previous) / 1000, 0.001, 0.032);
      previous = now;
      const acceleration =
        -omega * omega * (value - to) - 2 * damping * omega * speed;
      speed += acceleration * dt;
      value += speed * dt;
      onUpdate?.(value);
      if (Math.abs(value - to) < 0.12 && Math.abs(speed) < 1.2) {
        onUpdate?.(to);
        onComplete?.();
        return;
      }
      frame = requestAnimationFrame(tick);
    }

    frame = requestAnimationFrame(tick);
    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
    };
  }

  function trapFocus(container, event) {
    const focusable = Array.from(
      container.querySelectorAll(
        'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [href], [tabindex]:not([tabindex="-1"])',
      ),
    ).filter(isVisible);
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function isVisible(element) {
    if (!element || !element.isConnected) return false;
    if (element.closest("[hidden], [inert], [aria-hidden='true']")) return false;
    if (element.getClientRects().length === 0) return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden";
  }

  function focusInDirection(current, direction, root = document) {
    if (!(current instanceof HTMLElement)) return false;
    const source = current.getBoundingClientRect();
    if (!source.width || !source.height) return false;
    const vertical = direction === "up" || direction === "down";
    const forward = direction === "down" || direction === "right";
    const ahead = [];

    for (const node of root.querySelectorAll(
      'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [href], [tabindex]:not([tabindex="-1"])',
    )) {
      if (node === current || !isVisible(node)) continue;
      const rect = node.getBoundingClientRect();
      if (!rect.width || !rect.height) continue;
      const beyond = vertical
        ? forward
          ? rect.top - source.bottom
          : source.top - rect.bottom
        : forward
          ? rect.left - source.right
          : source.left - rect.right;
      if (beyond < -0.5) continue;
      ahead.push([node, rect]);
    }

    if (!ahead.length) return false;
    const inBand = ahead.filter(([, rect]) =>
      vertical
        ? rect.left < source.right && rect.right > source.left
        : rect.top < source.bottom && rect.bottom > source.top,
    );
    const candidates = inBand.length ? inBand : ahead;
    const primary = (rect) =>
      vertical
        ? Math.abs(rect.top + rect.height / 2 - (source.top + source.height / 2))
        : Math.abs(rect.left + rect.width / 2 - (source.left + source.width / 2));
    const cross = (rect) =>
      vertical
        ? Math.abs(rect.left + rect.width / 2 - (source.left + source.width / 2))
        : Math.abs(rect.top + rect.height / 2 - (source.top + source.height / 2));
    candidates.sort((a, b) => {
      const byPrimary = primary(a[1]) - primary(b[1]);
      return inBand.length || byPrimary !== 0 ? byPrimary : cross(a[1]) - cross(b[1]);
    });
    const target = candidates[0][0];
    target.focus({ preventScroll: true });
    target.scrollIntoView({ block: "nearest", inline: "nearest" });
    return true;
  }

  function formatTime(seconds) {
    const safe = Math.max(0, Math.floor(seconds));
    const minutes = Math.floor(safe / 60);
    const rest = safe % 60;
    return `${minutes}:${String(rest).padStart(2, "0")}`;
  }

  // 共享设置存储：真实 AppSettings 走 SettingsStore 本地事务持久化，
  // 原型用 localStorage 对齐「保存后重开仍在 / 未保存离开要确认」的语义。
  const SETTINGS_KEY = "hgproto.settings.v1";
  const SettingsStore = {
    load(fallback = {}) {
      try {
        const raw = localStorage.getItem(SETTINGS_KEY);
        return raw ? { ...fallback, ...JSON.parse(raw) } : { ...fallback };
      } catch (_) {
        return { ...fallback };
      }
    },
    save(values) {
      try {
        localStorage.setItem(SETTINGS_KEY, JSON.stringify(values));
        return true;
      } catch (_) {
        return false;
      }
    },
    // 按控件在设置区中的稳定顺序序列化，无需在 HTML 上打标
    controls(root) {
      return Array.from(root.querySelectorAll(
        ".settings-content [data-dirty], .settings-content [data-switch], .settings-content [data-setting-key]",
      )).filter((node, index, all) => all.indexOf(node) === index);
    },
    collect(root) {
      const values = {};
      this.controls(root).forEach((node, index) => {
        values[index] = node.matches("[role='switch']")
          ? node.getAttribute("aria-checked") === "true"
          : String(node.value ?? "");
      });
      return values;
    },
    apply(root, values) {
      this.controls(root).forEach((node, index) => {
        const value = values[index];
        if (value === undefined) return;
        if (node.matches("[role='switch']")) node.setAttribute("aria-checked", String(Boolean(value)));
        else if (node.matches("input, select") && value !== "") node.value = String(value);
      });
    },
  };

  // 共享播放时钟：把「只弹 toast」的 seek 桩改成真实进度推进。
  // 原型没有真实媒体源，用一个按 rate 倍数推进的秒表驱动 currentTime / progress。
  // 注意：12:28 只是原型样例时长，真实时长来自 VideoTrack / 播放器 duration。
  function PlaybackClock({ duration = 748, initial = 302, onUpdate } = {}) {
    let position = initial;
    let playing = true;
    let rate = 1;
    let timer = null;
    const tick = () => {
      if (!playing) return;
      position = clamp(position + rate, 0, duration);
      if (position >= duration) playing = false;
      onUpdate?.(position, duration, playing);
    };
    timer = setInterval(tick, 1000);
    return {
      get position() { return position; },
      get duration() { return duration; },
      get playing() { return playing; },
      get rate() { return rate; },
      setPlaying(value) { playing = Boolean(value); },
      setRate(value) { rate = Number(value) > 0 ? Number(value) : 1; },
      seek(seconds) {
        position = clamp(position + Number(seconds || 0), 0, duration);
        onUpdate?.(position, duration, playing);
        return position;
      },
      seekTo(seconds) {
        position = clamp(Number(seconds) || 0, 0, duration);
        onUpdate?.(position, duration, playing);
        return position;
      },
      dispose() { clearInterval(timer); },
    };
  }

  // 换源面板：对齐 showSourceSwitch() + SourceResolver.resolve（8s 预算 / 命中未命中）
  // 数据来自 detail().tracks 的真字段 quality/format/candidates/fromWeb。
  function SourceSwitch({ tracks = [], currentId = "", onChoose, onClose } = {}) {
    const layer = document.createElement("div");
    layer.className = "source-layer";
    layer.setAttribute("role", "dialog");
    layer.setAttribute("aria-modal", "true");
    layer.setAttribute("aria-label", "切换播放线路");
    layer.innerHTML = `<section class="source-panel">
      <div class="source-head"><div><h2>切换播放线路</h2><p>同源多线路按 candidates 顺序回退 · 解析预算 8 秒</p></div>
      <button type="button" class="icon-button" data-source-close aria-label="关闭">${icon("close")}</button></div>
      <div class="source-list">${tracks.map((t) => `<button type="button" class="source-option" data-source-id="${t.id}" aria-pressed="${t.id === currentId}">
        <span class="source-quality">${t.quality || "自动"}</span>
        <span class="source-copy"><strong>${t.label || t.id}</strong><small>${t.fromWeb ? "网页直链" : t.format || "mp4"} · ${t.candidates || 1} 条备用</small></span>
        <span class="source-state">${t.id === currentId ? "当前" : "可选"}</span>
      </button>`).join("")}</div>
      <div class="source-foot"><span data-source-result>选择线路后将重新解析播放地址</span></div>
    </section>`;
    document.body.appendChild(layer);
    const close = () => { layer.remove(); onClose?.(); };
    layer.addEventListener("click", (event) => {
      if (event.target === layer || event.target.closest("[data-source-close]")) { close(); return; }
      const option = event.target.closest("[data-source-id]");
      if (!option) return;
      const id = option.dataset.sourceId;
      const result = layer.querySelector("[data-source-result]");
      result.textContent = "正在解析播放地址…";
      // 模拟 SourceResolver.resolve 的 8s 预算：命中即切，未命中回退第一条可用线路
      const chosen = tracks.find((t) => t.id === id);
      setTimeout(() => {
        const hit = Boolean(chosen?.playable);
        result.textContent = hit ? `解析成功 · 已切到 ${chosen.quality || "自动"} 线路` : "解析超时，已回退到第一条可用线路";
        onChoose?.(hit ? id : tracks.find((t) => t.playable)?.id || id, { hit, budget: 8000 });
        setTimeout(close, 420);
      }, 480);
    });
    layer.querySelector("[data-source-close]")?.focus({ preventScroll: true });
    return { close, element: layer };
  }

  // 共享「我的」个人中心：把 Mobile 端的真结构与交互抽成公共组件，
  // PC / TV / iPad 调用同一份实现，避免四端页面各写一套导致行为漂移。
  // 数据字段名与存储键对齐 PreferencesBackend.read()：
  // favorites=[], history=WatchRecord[], 进度键 `<dramaId>:<vid>`。
  function PersonalCenter({
    mount,
    Data,
    onOpenDetail,
    onContinue,
    onSettings,
    toast,
    emptyState,
    focusClass = "",
  } = {}) {
    if (!mount || !Data) return null;
    const escape = (value) => String(value ?? "").replace(/[&<>"']/g, (ch) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    const durationText = (ms) => {
      const total = Math.max(0, Math.round(Number(ms) / 1000));
      return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
    };
    const sizeText = (bytes) => {
      const size = Number(bytes) || 0;
      return size >= 1e9 ? `${(size / 1e9).toFixed(2)} GB` : `${Math.round(size / 1e6)} MB`;
    };
    const placeholder = (title, message) => (typeof emptyState === "function"
      ? emptyState(title, message)
      : `<div class="data-state"><strong>${escape(title)}</strong><p>${escape(message)}</p></div>`);
    const row = (item, meta, action) => `<div class="mine-row">
      <span class="mine-row-thumb" style="background:${escape(item.dominateColor || "#282828")}"><img src="${escape(item.poster || "")}" alt="" /></span>
      <span class="mine-row-copy"><strong>${escape(item.title || "未命名")}</strong><small>${escape(meta)}</small></span>
      <button type="button" class="icon-button" ${action} aria-label="查看详情">${icon("forward")}</button>
    </div>`;

    // 事件只绑定一次；render() 可以被反复调用而不重复注册。
    mount.addEventListener("click", (event) => {
      const jump = event.target.closest("[data-pc-jump]");
      if (jump) {
        mount.querySelector(`#${jump.dataset.pcJump}`)?.scrollIntoView({ behavior: "smooth", block: "start" });
        return;
      }
      const cont = event.target.closest("[data-pc-continue]");
      if (cont) {
        onContinue?.(cont.dataset.pcContinue, Number(cont.dataset.episode) || 1);
        return;
      }
      const detail = event.target.closest("[data-pc-detail]");
      if (detail) { onOpenDetail?.(detail.dataset.pcDetail); return; }
      const settings = event.target.closest("[data-pc-settings]");
      if (settings) onSettings?.();
    });

    async function render() {
      let data;
      try {
        data = await Data.personal();
      } catch (error) {
        mount.innerHTML = placeholder("本地数据读取失败", error?.message || "请稍后重试");
        return;
      }
      // 一次性写入完整结构，避免先清空占位后 querySelector 落空。
      mount.innerHTML = `<div class="mine-header">
          <div class="mine-avatar">红</div>
          <div class="mine-identity"><strong>${escape(data.displayName)}</strong><span>本地账号 · 数据仅存本机</span></div>
          <button type="button" class="icon-button" data-pc-settings aria-label="设置">${icon("settings")}</button>
        </div>
        <div class="mine-stats" aria-label="个人数据概览"></div>
        <div class="mine-quick-grid" aria-label="常用入口"></div>
        <div class="mine-section" id="mineHistory"><div class="section-head"><h2>继续观看</h2><p>观看历史 · WatchRecord</p></div><div id="mineHistoryList"></div></div>
        <div class="mine-section" id="mineFavSection"><div class="section-head"><h2>我的追剧</h2><p>favorites</p></div><div class="mine-row-list" id="mineFavorites"></div></div>
        <div class="mine-section" id="mineDownloadSection"><div class="section-head"><h2>缓存与下载</h2><p>本地文件 · DownloadRuntime</p></div><div id="mineDownloads"></div></div>
        <div class="mine-section" id="mineReserveSection"><div class="section-head"><h2>预约更新</h2><p>更新提醒</p></div><div class="mine-row-list" id="mineReservations"></div></div>
        <p class="mine-foot">${escape(data.source)} · 键：${escape(data.keys.join(" / "))}</p>`;

      mount.querySelector(".mine-stats").innerHTML = [
        ["追剧", data.stats.favorites], ["观看历史", data.stats.history],
        ["已缓存", data.stats.downloads], ["预约", data.stats.reservations],
      ].map(([label, value]) => `<div class="mine-stat"><strong>${value}</strong><span>${label}</span></div>`).join("");

      mount.querySelector(".mine-quick-grid").innerHTML = [
        ["history", "观看历史", "mineHistory"], ["download", "缓存管理", "mineDownloadSection"],
        ["heart", "我的追剧", "mineFavSection"], ["bell", "预约更新", "mineReserveSection"],
      ].map(([iconName, label, target]) => `<button type="button" class="mine-quick" data-pc-jump="${target}">${icon(iconName)}<span>${label}</span></button>`).join("");

      mount.querySelector("#mineHistoryList").innerHTML = data.history.length
        ? data.history.map((record) => {
          const drama = Data.dramaById(record.drama) || Data.allDramas()[0];
          const progress = Math.round((record.positionMs / Math.max(1, record.durationMs)) * 100);
          return `<div class="mine-history">
            <button type="button" class="mine-row" data-pc-detail="${escape(drama.id)}">
              <span class="mine-row-thumb" style="background:${escape(drama.dominateColor)}"><img src="${escape(drama.poster)}" alt="" /></span>
              <span class="mine-row-copy"><strong>${escape(drama.title)}</strong>
                <small>第 ${record.episode} 集 · ${durationText(record.positionMs)} / ${durationText(record.durationMs)} · ${escape(record.quality)}${record.local ? " · 本地" : ""}</small>
                <span class="mine-progress"><i style="width:${progress}%"></i></span>
              </span>
            </button>
            <button type="button" class="button ghost" data-pc-continue="${escape(drama.id)}" data-episode="${record.episode}">续播</button>
          </div>`;
        }).join("")
        : placeholder("暂无观看记录", "播放后会自动记录断点（WatchRecord）");

      mount.querySelector("#mineFavorites").innerHTML = data.favorites.length
        ? data.favorites.map((item) => row(item, "追剧更新提醒", `data-pc-detail="${escape(item.dramaId)}"`)).join("")
        : placeholder("还没有追剧", "详情页点「追剧」加入 favorites");

      mount.querySelector("#mineDownloads").innerHTML = data.downloads.length
        ? data.downloads.map((item) => {
          const done = item.status === "done";
          return `<div class="mine-download"><div class="mine-row">
            <span class="mine-row-thumb" style="background:#282828"><span class="mine-row-fallback">${escape(item.title.slice(0, 1))}</span></span>
            <span class="mine-row-copy"><strong>${escape(item.title)}</strong>
              <small>第 ${item.episode} 集 · ${escape(item.quality)} · ${sizeText(item.sizeBytes)} · ${done ? "已完成" : `下载中 ${Math.round(item.progress * 100)}%`}</small>
              ${done ? "" : `<span class="mine-progress"><i style="width:${Math.round(item.progress * 100)}%"></i></span>`}
            </span>
            <span class="mine-download-status" data-status="${item.status}">${done ? "已缓存" : "后台"}</span>
          </div></div>`;
        }).join("")
        : placeholder("暂无缓存", "仅 Wi-Fi 下载，缓存文件存本机");

      mount.querySelector("#mineReservations").innerHTML = data.reservations.length
        ? data.reservations.map((item) => row(item, "上线后提醒", `data-pc-detail="${escape(item.dramaId)}"`)).join("")
        : placeholder("暂无预约", "预告片或续订剧集可预约提醒");

      if (focusClass) mount.querySelectorAll("button").forEach((button) => button.classList.add(focusClass));
      hydrateIcons(mount);
    }

    return { render };
  }

  window.HGProto = {
    clamp,
    fitFrame,
    focusInDirection,
    formatTime,
    hydrateIcons,
    icon,
    isVisible,
    PersonalCenter,
    PlaybackClock,
    focusInDirection,
    formatTime,
    hydrateIcons,
    icon,
    isVisible,
    PlaybackClock,
    SettingsStore,
    SourceSwitch,
    project,
    spring,
    trapFocus,
  };
})();
