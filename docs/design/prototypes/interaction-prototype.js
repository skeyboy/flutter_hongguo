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

  window.HGProto = {
    clamp,
    fitFrame,
    focusInDirection,
    formatTime,
    hydrateIcons,
    icon,
    isVisible,
    project,
    spring,
    trapFocus,
  };
})();
