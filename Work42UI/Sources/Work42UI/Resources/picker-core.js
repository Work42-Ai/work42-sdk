(function() {
  "use strict";
  const NON_VISUAL_TAGS = /* @__PURE__ */ new Set([
    "script",
    "style",
    "link",
    "meta",
    "noscript",
    "head",
    "html",
    "body"
  ]);
  const OVERLAY_IDS = {
    hoverBox: "web42-picker-hover-box",
    hoverLabel: "web42-picker-hover-label"
  };
  const SELECTION_CLASS = "web42-picker-selection";
  function cssEscape(value) {
    if (typeof window.CSS !== "undefined" && typeof window.CSS.escape === "function") {
      return window.CSS.escape(value);
    }
    return value.replace(/[^a-zA-Z0-9_-]/g, (char) => `\\${char}`);
  }
  function parseSelector(selector) {
    const match = selector.match(/^(.+);\((\d+)\)$/);
    if (match) {
      return { base: match[1], index: Number(match[2]) };
    }
    return { base: selector, index: null };
  }
  function resolveSelector(selector) {
    const { base, index } = parseSelector(selector);
    let elements;
    try {
      elements = document.querySelectorAll(base);
    } catch {
      return null;
    }
    if (elements.length === 0) return null;
    if (elements.length === 1) return elements[0];
    if (index !== null && index >= 0 && index < elements.length) {
      return elements[index];
    }
    return elements[0];
  }
  function normalizeText(value) {
    return value.replace(/\s+/g, " ").trim();
  }
  function generateSelector(element) {
    const htmlEl = element;
    if (htmlEl.id) {
      return `#${cssEscape(htmlEl.id)}`;
    }
    const tag = htmlEl.tagName.toLowerCase();
    const classes = Array.from(htmlEl.classList).filter(
      (className) => className && !className.startsWith("web42-") && !className.startsWith("hb-")
    );
    let baseSelector = tag;
    if (classes.length > 0) {
      const escapedClasses = classes.map((className) => cssEscape(className));
      baseSelector = `${tag}.${escapedClasses.join(".")}`;
    }
    try {
      const matches = document.querySelectorAll(baseSelector);
      if (matches.length === 1) {
        return baseSelector;
      }
      if (matches.length > 1) {
        const index = Array.from(matches).indexOf(element);
        if (index >= 0) {
          return `${baseSelector};(${index})`;
        }
      }
    } catch {
    }
    const parent = element.parentElement;
    if (parent == null ? void 0 : parent.id) {
      const contextualBase = `#${cssEscape(parent.id)} > ${baseSelector}`;
      try {
        const matches = document.querySelectorAll(contextualBase);
        if (matches.length === 1) {
          return contextualBase;
        }
        if (matches.length > 1) {
          const index = Array.from(matches).indexOf(element);
          if (index >= 0) {
            return `${contextualBase};(${index})`;
          }
        }
      } catch {
      }
    }
    return baseSelector;
  }
  function extractTextFromSelectors(selectors) {
    const chunks = [];
    const seen = /* @__PURE__ */ new Set();
    for (const selector of selectors) {
      const element = resolveSelector(selector);
      if (!element) continue;
      const text = normalizeText(element.innerText || element.textContent || "");
      if (!text || seen.has(text)) continue;
      seen.add(text);
      chunks.push(text);
    }
    return chunks.join("\n\n");
  }
  function getVisibleBoundsFromSelectors(selectors) {
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;
    let minLeft = Number.POSITIVE_INFINITY;
    let minTop = Number.POSITIVE_INFINITY;
    let maxRight = Number.NEGATIVE_INFINITY;
    let maxBottom = Number.NEGATIVE_INFINITY;
    for (const selector of selectors) {
      const element = resolveSelector(selector);
      if (!element) continue;
      const rect = element.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const left = Math.max(0, rect.left);
      const top = Math.max(0, rect.top);
      const right = Math.min(viewportWidth, rect.right);
      const bottom = Math.min(viewportHeight, rect.bottom);
      if (right <= left || bottom <= top) continue;
      minLeft = Math.min(minLeft, left);
      minTop = Math.min(minTop, top);
      maxRight = Math.max(maxRight, right);
      maxBottom = Math.max(maxBottom, bottom);
    }
    if (!Number.isFinite(minLeft) || !Number.isFinite(minTop) || !Number.isFinite(maxRight) || !Number.isFinite(maxBottom)) {
      return {
        ok: false,
        error: "No selected elements are currently visible in the viewport. Scroll them into view and try again."
      };
    }
    const padding = 12;
    const paddedLeft = Math.max(0, Math.floor(minLeft) - padding);
    const paddedTop = Math.max(0, Math.floor(minTop) - padding);
    const paddedRight = Math.min(viewportWidth, Math.ceil(maxRight) + padding);
    const paddedBottom = Math.min(viewportHeight, Math.ceil(maxBottom) + padding);
    const width = Math.max(1, paddedRight - paddedLeft);
    const height = Math.max(1, paddedBottom - paddedTop);
    if (width <= 0 || height <= 0) {
      return {
        ok: false,
        error: "Could not calculate a valid visible crop area for the selected elements."
      };
    }
    return {
      ok: true,
      bounds: {
        x: paddedLeft,
        y: paddedTop,
        width,
        height,
        viewportWidth,
        viewportHeight
      }
    };
  }
  function isOverlayElement(element) {
    if (!element) return false;
    return Boolean(
      element.id === OVERLAY_IDS.hoverBox || element.id === OVERLAY_IDS.hoverLabel || element.classList.contains(SELECTION_CLASS) || element.closest(`#${OVERLAY_IDS.hoverBox}`) || element.closest(`#${OVERLAY_IDS.hoverLabel}`) || element.closest(`.${SELECTION_CLASS}`) || element.closest("[data-w42-selection]")
    );
  }
  function isSemanticNode(element) {
    return element instanceof Element && typeof element.matches === "function" && element.matches('[aria-label],[role],flt-semantics,[id^="flt-semantic-node"]');
  }
  function semanticDescriptor(element) {
    if (!isSemanticNode(element)) return null;
    const role = (element.getAttribute("role") || "").trim();
    let name = (element.getAttribute("aria-label") || "").trim();
    if (!name) name = normalizeText(element.textContent || "");
    if (!name) return null;
    return { role, name };
  }
  function isPickable(element) {
    if (!(element instanceof HTMLElement)) return false;
    if (isOverlayElement(element)) return false;
    const tagName = element.tagName.toLowerCase();
    if (NON_VISUAL_TAGS.has(tagName)) return false;
    const rect = element.getBoundingClientRect();
    // Augment (not swap): semantic nodes (Flutter a11y / ARIA) are pickable even
    // when small, so everything the scan surfaces is reachable in the picker too.
    // Generic DOM elements keep the 20px minimum.
    if (isSemanticNode(element)) return rect.width >= 4 && rect.height >= 4;
    return rect.width >= 20 && rect.height >= 20;
  }
  function ensureOverlayElements(hoverBoxRef, hoverLabelRef, accentColor) {
    if (!hoverBoxRef.el) {
      const box = document.createElement("div");
      box.id = OVERLAY_IDS.hoverBox;
      box.style.cssText = [
        "position: fixed",
        "pointer-events: none",
        "z-index: 2147483645",
        `border: 2px solid ${accentColor}`,
        `background: ${hexToRgba(accentColor, 0.1)}`,
        "display: none",
        "box-sizing: border-box",
        "transition: all 80ms linear"
      ].join(";");
      document.documentElement.appendChild(box);
      hoverBoxRef.el = box;
    }
    if (!hoverLabelRef.el) {
      const label = document.createElement("div");
      label.id = OVERLAY_IDS.hoverLabel;
      label.style.cssText = [
        "position: fixed",
        "pointer-events: none",
        "z-index: 2147483646",
        `background: ${accentColor}`,
        "color: #fff",
        "font: 11px/1.2 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
        "padding: 2px 6px",
        "border-radius: 3px",
        "display: none",
        "max-width: 320px",
        "white-space: nowrap",
        "overflow: hidden",
        "text-overflow: ellipsis"
      ].join(";");
      document.documentElement.appendChild(label);
      hoverLabelRef.el = label;
    }
  }
  function hideHoverOverlay(hoverBoxEl, hoverLabelEl) {
    if (hoverBoxEl) hoverBoxEl.style.display = "none";
    if (hoverLabelEl) hoverLabelEl.style.display = "none";
  }
  function positionHoverOverlay(element, hoverBoxEl, hoverLabelEl) {
    if (!hoverBoxEl || !hoverLabelEl) return;
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) {
      hideHoverOverlay(hoverBoxEl, hoverLabelEl);
      return;
    }
    hoverBoxEl.style.display = "block";
    hoverBoxEl.style.top = `${rect.top}px`;
    hoverBoxEl.style.left = `${rect.left}px`;
    hoverBoxEl.style.width = `${rect.width}px`;
    hoverBoxEl.style.height = `${rect.height}px`;
    const sem = semanticDescriptor(element);
    if (sem) {
      hoverLabelEl.textContent = (sem.role ? sem.role + ": " : "") + sem.name;
    } else {
      const tagName = element.tagName.toLowerCase();
      const idPart = element.id ? `#${element.id}` : "";
      hoverLabelEl.textContent = `${tagName}${idPart} (${Math.round(rect.width)}x${Math.round(rect.height)})`;
    }
    hoverLabelEl.style.display = "block";
    hoverLabelEl.style.left = `${Math.max(4, rect.left)}px`;
    hoverLabelEl.style.top = `${rect.top > 24 ? rect.top - 22 : rect.bottom + 4}px`;
  }
  function hexToRgba(hex, alpha) {
    const m = hex.replace(/^#/, "").match(/^([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/);
    if (!m) return `rgba(59, 130, 246, ${alpha})`;
    const r = parseInt(m[1], 16);
    const g = parseInt(m[2], 16);
    const b = parseInt(m[3], 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }
  function createPickerCore(callbacks, options) {
    const accentColor = (options == null ? void 0 : options.accentColor) ?? "#3b82f6";
    let pickerActive = false;
    let currentElement = null;
    let hoveredSelector;
    const hoverBoxRef = { el: null };
    const hoverLabelRef = { el: null };
    const capturedItems = [];
    const selectionOverlayDivs = /* @__PURE__ */ new Map();
    let selectionRafId = null;
    let pickCount = 0;
    function selectionLoop() {
      for (const item of capturedItems) {
        const el = resolveSelector(item.selector);
        let div = selectionOverlayDivs.get(item.selector);
        if (!div) {
          div = document.createElement("div");
          div.dataset.w42Selection = "1";
          div.style.cssText = [
            "position: fixed",
            "pointer-events: none",
            `z-index: 2147483646`,
            `border: 2px solid ${accentColor}`,
            `background: ${hexToRgba(accentColor, 0.1)}`,
            "box-sizing: border-box"
          ].join(";");
          document.documentElement.appendChild(div);
          selectionOverlayDivs.set(item.selector, div);
        }
        if (el) {
          const r = el.getBoundingClientRect();
          div.style.display = "block";
          div.style.top = `${r.top}px`;
          div.style.left = `${r.left}px`;
          div.style.width = `${r.width}px`;
          div.style.height = `${r.height}px`;
        } else {
          div.style.display = "none";
        }
      }
      if (capturedItems.length > 0) {
        selectionRafId = requestAnimationFrame(selectionLoop);
      }
    }
    function startSelectionLoop() {
      if (selectionRafId !== null) return;
      selectionRafId = requestAnimationFrame(selectionLoop);
    }
    function stopSelectionLoop() {
      if (selectionRafId !== null) {
        cancelAnimationFrame(selectionRafId);
        selectionRafId = null;
      }
    }
    function emitState() {
      callbacks.emit({ active: pickerActive, hoveredSelector });
    }
    function handleMouseMove(event) {
      if (!pickerActive) return;
      const element = document.elementFromPoint(event.clientX, event.clientY);
      if (!element || !isPickable(element)) {
        if (!currentElement && !hoveredSelector) return;
        currentElement = null;
        hoveredSelector = void 0;
        hideHoverOverlay(hoverBoxRef.el, hoverLabelRef.el);
        emitState();
        return;
      }
      const selector = generateSelector(element);
      if (selector === hoveredSelector && currentElement === element) return;
      currentElement = element;
      hoveredSelector = selector;
      positionHoverOverlay(element, hoverBoxRef.el, hoverLabelRef.el);
      emitState();
    }
    function handleMouseLeave() {
      if (!pickerActive) return;
      currentElement = null;
      hoveredSelector = void 0;
      hideHoverOverlay(hoverBoxRef.el, hoverLabelRef.el);
      emitState();
    }
    function handleClick(event) {
      var _a;
      if (!pickerActive) return;
      const target = event.target;
      if (!(target instanceof Element)) return;
      if (!currentElement || isOverlayElement(target)) {
        event.preventDefault();
        event.stopPropagation();
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      const clickedSelector = generateSelector(currentElement);
      const existingIndex = capturedItems.findIndex((item) => item.selector === clickedSelector);
      if (existingIndex !== -1) {
        capturedItems.splice(existingIndex, 1);
        const div = selectionOverlayDivs.get(clickedSelector);
        if (div) {
          div.remove();
          selectionOverlayDivs.delete(clickedSelector);
        }
        if (capturedItems.length === 0) stopSelectionLoop();
        (_a = callbacks.deselect) == null ? void 0 : _a.call(callbacks, clickedSelector);
        return;
      }
      const rect = currentElement.getBoundingClientRect();
      // Augment the captured text with the semantic identity (role + accessible
      // name) so a pick carries the SAME data the scan returns for this element.
      const sem = semanticDescriptor(currentElement);
      const text = sem ? (sem.role ? sem.role + ": " + sem.name : sem.name) : normalizeText(
        currentElement.innerText || currentElement.textContent || ""
      );
      hideHoverOverlay(hoverBoxRef.el, hoverLabelRef.el);
      pickCount += 1;
      capturedItems.push({ selector: clickedSelector, pickNumber: pickCount });
      startSelectionLoop();
      const viewportWidth = window.innerWidth;
      const viewportHeight = window.innerHeight;
      const clampedX = Math.max(0, Math.min(viewportWidth, rect.left));
      const clampedY = Math.max(0, Math.min(viewportHeight, rect.top));
      const clampedWidth = Math.max(0, Math.min(viewportWidth - clampedX, rect.width));
      const clampedHeight = Math.max(0, Math.min(viewportHeight - clampedY, rect.height));
      callbacks.capture({
        selector: clickedSelector,
        bounds: {
          x: clampedX,
          y: clampedY,
          width: clampedWidth,
          height: clampedHeight,
          viewportWidth,
          viewportHeight
        },
        text,
        url: window.location.href
      });
    }
    function handleSuppressInteraction(event) {
      if (!pickerActive) return;
      const target = event.target;
      if (target instanceof Element && isOverlayElement(target)) return;
      event.preventDefault();
      event.stopPropagation();
    }
    function handleViewportChange() {
      if (!pickerActive) return;
      if (currentElement) {
        positionHoverOverlay(currentElement, hoverBoxRef.el, hoverLabelRef.el);
      }
    }
    function removeOverlayElements() {
      stopSelectionLoop();
      for (const div of selectionOverlayDivs.values()) {
        div.remove();
      }
      selectionOverlayDivs.clear();
      capturedItems.length = 0;
      pickCount = 0;
      if (hoverBoxRef.el) {
        hoverBoxRef.el.remove();
        hoverBoxRef.el = null;
      }
      if (hoverLabelRef.el) {
        hoverLabelRef.el.remove();
        hoverLabelRef.el = null;
      }
    }
    return {
      start() {
        pickerActive = true;
        currentElement = null;
        hoveredSelector = void 0;
        stopSelectionLoop();
        for (const div of selectionOverlayDivs.values()) {
          div.remove();
        }
        selectionOverlayDivs.clear();
        capturedItems.length = 0;
        pickCount = 0;
        ensureOverlayElements(hoverBoxRef, hoverLabelRef, accentColor);
        document.addEventListener("mousemove", handleMouseMove, { passive: true });
        document.addEventListener("mouseleave", handleMouseLeave, { passive: true });
        document.addEventListener("click", handleClick, true);
        document.addEventListener("mousedown", handleSuppressInteraction, true);
        document.addEventListener("mouseup", handleSuppressInteraction, true);
        document.addEventListener("dblclick", handleSuppressInteraction, true);
        document.addEventListener("contextmenu", handleSuppressInteraction, true);
        document.addEventListener("touchstart", handleSuppressInteraction, true);
        document.addEventListener("touchend", handleSuppressInteraction, true);
        window.addEventListener("scroll", handleViewportChange, { passive: true });
        window.addEventListener("resize", handleViewportChange, { passive: true });
        emitState();
      },
      stop() {
        pickerActive = false;
        currentElement = null;
        hoveredSelector = void 0;
        document.removeEventListener("mousemove", handleMouseMove);
        document.removeEventListener("mouseleave", handleMouseLeave);
        document.removeEventListener("click", handleClick, true);
        document.removeEventListener("mousedown", handleSuppressInteraction, true);
        document.removeEventListener("mouseup", handleSuppressInteraction, true);
        document.removeEventListener("dblclick", handleSuppressInteraction, true);
        document.removeEventListener("contextmenu", handleSuppressInteraction, true);
        document.removeEventListener("touchstart", handleSuppressInteraction, true);
        document.removeEventListener("touchend", handleSuppressInteraction, true);
        window.removeEventListener("scroll", handleViewportChange);
        window.removeEventListener("resize", handleViewportChange);
        removeOverlayElements();
        emitState();
      },
      isActive() {
        return pickerActive;
      },
      onViewportChange() {
        handleViewportChange();
      }
    };
  }
  const pickerCoreAPI = {
    createPickerCore,
    cssEscape,
    parseSelector,
    resolveSelector,
    normalizeText,
    generateSelector,
    extractTextFromSelectors,
    getVisibleBoundsFromSelectors,
    positionHoverOverlay,
    isPickable
  };
  window.__pickerCore = pickerCoreAPI;
})();
