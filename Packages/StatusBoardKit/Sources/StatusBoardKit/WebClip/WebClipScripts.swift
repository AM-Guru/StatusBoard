import Foundation

/// JavaScript shared by every surface that renders or edits web clips: the
/// live panel web views (iOS/macOS), the element picker, and the Mac bridge's
/// offscreen renderer that serves Apple TV.
public enum WebClipScripts {

    /// Applies region isolation and element hiding.
    ///
    /// Isolation works by walking from the target up to `<body>` and hiding
    /// every *sibling* along the way, then neutralizing the ancestors' own
    /// layout (margins, padding, width caps, transforms, sticky positioning).
    /// The target is left as the only laid-out content, so it lands at the top
    /// of the document — no scrolling tricks, and it survives reflow. A
    /// MutationObserver re-applies everything when single-page apps re-render.
    public static func clipScript(selector: String?, hideSelectors: [String],
                                  zoom: Double = 1) -> String {
        """
        (function() {
          var SEL = \(jsonString(selector ?? ""));
          var HIDES = \(jsonString(hideSelectors));
          var MARK = 'data-sb-clip';

          function styleTag() {
            var el = document.getElementById('__sb_clip_style');
            if (!el) {
              el = document.createElement('style');
              el.id = '__sb_clip_style';
              (document.head || document.documentElement).appendChild(el);
            }
            return el;
          }

          // Element hiding is pure CSS so it costs nothing to re-apply.
          function applyHides() {
            var css = '';
            for (var i = 0; i < HIDES.length; i++) {
              if (HIDES[i]) { css += HIDES[i] + '{display:none !important;}\\n'; }
            }
            if (SEL) {
              // Neutralize page chrome that would otherwise letterbox the clip.
              css += 'html,body{margin:0 !important;padding:0 !important;' +
                     'overflow:visible !important;height:auto !important;' +
                     'min-height:0 !important;background:transparent !important;}\\n';
              css += '[' + MARK + '="hidden"]{display:none !important;}\\n';
              css += '[' + MARK + '="ancestor"]{display:block !important;' +
                     'position:static !important;margin:0 !important;padding:0 !important;' +
                     'width:auto !important;max-width:none !important;min-width:0 !important;' +
                     'height:auto !important;max-height:none !important;min-height:0 !important;' +
                     'transform:none !important;overflow:visible !important;' +
                     'float:none !important;background:transparent !important;' +
                     'border:0 !important;box-shadow:none !important;}\\n';
              css += '[' + MARK + '="target"]{margin:0 !important;' +
                     'max-width:none !important;position:static !important;' +
                     'transform:none !important;float:none !important;}\\n';
            }
            styleTag().textContent = css;
          }

          function clearMarks() {
            var marked = document.querySelectorAll('[' + MARK + ']');
            for (var i = 0; i < marked.length; i++) {
              marked[i].removeAttribute(MARK);
            }
          }

          function applyIsolation() {
            clearMarks();
            if (!SEL) { return true; }
            var target;
            try { target = document.querySelector(SEL); } catch (e) { return false; }
            if (!target) { return false; }

            target.setAttribute(MARK, 'target');
            var node = target;
            var parent = node.parentElement;
            while (parent && node !== document.body) {
              var kids = parent.children;
              for (var i = 0; i < kids.length; i++) {
                if (kids[i] !== node && !kids[i].hasAttribute(MARK)) {
                  // Never hide the stylesheet we're driving all this with.
                  if (kids[i].id !== '__sb_clip_style') {
                    kids[i].setAttribute(MARK, 'hidden');
                  }
                }
              }
              if (parent !== document.body && parent !== document.documentElement) {
                parent.setAttribute(MARK, 'ancestor');
              }
              node = parent;
              parent = node.parentElement;
            }
            window.scrollTo(0, 0);
            return true;
          }

          function apply() {
            applyHides();
            applyIsolation();
          }

          apply();

          // Re-apply when the page mutates (SPA navigation, lazy content),
          // debounced so we don't fight the page's own rendering.
          if (!window.__sbClipObserver) {
            var pending = null;
            window.__sbClipObserver = new MutationObserver(function() {
              if (pending) { return; }
              pending = setTimeout(function() {
                pending = null;
                window.__sbClipApply && window.__sbClipApply();
              }, 250);
            });
            try {
              window.__sbClipObserver.observe(document.documentElement,
                                              {childList: true, subtree: true});
            } catch (e) {}
          }
          window.__sbClipApply = apply;
        })();
        """
    }

    /// Removes any isolation/hiding so the picker can show the raw page again.
    public static let resetScript = """
    (function() {
      if (window.__sbClipObserver) {
        window.__sbClipObserver.disconnect();
        window.__sbClipObserver = null;
      }
      window.__sbClipApply = null;
      var style = document.getElementById('__sb_clip_style');
      if (style) { style.textContent = ''; }
      var marked = document.querySelectorAll('[data-sb-clip]');
      for (var i = 0; i < marked.length; i++) {
        marked[i].removeAttribute('data-sb-clip');
      }
    })();
    """

    /// `[x, y, width, height]` of the isolated element in CSS pixels, or null.
    /// Used by the bridge to crop its snapshot.
    public static func rectScript(selector: String) -> String {
        """
        (function() {
          var el;
          try { el = document.querySelector(\(jsonString(selector))); } catch (e) { return null; }
          if (!el) { return null; }
          var r = el.getBoundingClientRect();
          return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height];
        })();
        """
    }

    // MARK: - Picker

    /// The interactive picker. Tracks a *current* element so the region can be
    /// expanded outward to its parent or contracted inward to its largest
    /// child — the 1Blocker-style flow — and reports the selection back to the
    /// `sbPicker` message handler on every change.
    public static let pickerScript = """
    (function() {
      if (window.__sbPickerInstalled) { return; }
      window.__sbPickerInstalled = true;
      if (window.__sbPickEnabled === undefined) { window.__sbPickEnabled = true; }
      window.__sbCurrent = null;

      var hover = document.createElement('div');
      hover.id = '__sb_pick_hover';
      hover.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;' +
        'border:1px dashed rgba(255,160,40,0.9);background:rgba(255,160,40,0.10);' +
        'border-radius:3px;display:none;box-sizing:border-box;';
      var chosen = document.createElement('div');
      chosen.id = '__sb_pick_chosen';
      chosen.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;' +
        'border:3px solid #FFA028;background:rgba(255,160,40,0.16);' +
        'border-radius:4px;display:none;box-sizing:border-box;' +
        'box-shadow:0 0 0 2000px rgba(0,0,0,0.35);';
      document.documentElement.appendChild(hover);
      document.documentElement.appendChild(chosen);

      function esc(v) {
        return (window.CSS && CSS.escape) ? CSS.escape(v) : v.replace(/[^a-zA-Z0-9_-]/g, '\\\\$&');
      }

      function selectorFor(el) {
        if (el.id) { return '#' + esc(el.id); }
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1 && node !== document.body && node !== document.documentElement) {
          var part = node.tagName.toLowerCase();
          var classes = Array.prototype.slice.call(node.classList, 0, 2);
          for (var i = 0; i < classes.length; i++) {
            if (/^[A-Za-z][\\w-]*$/.test(classes[i])) { part += '.' + esc(classes[i]); }
          }
          var parent = node.parentElement;
          if (parent) {
            var sameTag = Array.prototype.filter.call(parent.children, function(c) {
              return c.tagName === node.tagName;
            });
            if (sameTag.length > 1) {
              part += ':nth-of-type(' + (sameTag.indexOf(node) + 1) + ')';
            }
          }
          parts.unshift(part);
          if (parent && parent.id) {
            parts.unshift('#' + esc(parent.id));
            break;
          }
          node = parent;
        }
        return parts.length ? parts.join(' > ') : 'body';
      }

      function outline(box, el) {
        if (!el || window.__sbOverlaysHidden) { box.style.display = 'none'; return; }
        var r = el.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px';
        box.style.top = r.top + 'px';
        box.style.width = r.width + 'px';
        box.style.height = r.height + 'px';
      }

      // The biggest element child — the most useful "inward" step, since it
      // skips past wrapper divs that add nothing.
      function largestChild(el) {
        var best = null, bestArea = 0;
        for (var i = 0; i < el.children.length; i++) {
          var c = el.children[i];
          if (c === hover || c === chosen) { continue; }
          if (c.id === '__sb_clip_style') { continue; }
          var r = c.getBoundingClientRect();
          var area = r.width * r.height;
          if (area > bestArea) { bestArea = area; best = c; }
        }
        return best;
      }

      function report() {
        var el = window.__sbCurrent;
        outline(chosen, el);
        if (!el) {
          window.webkit.messageHandlers.sbPicker.postMessage({event: 'cleared'});
          return;
        }
        var r = el.getBoundingClientRect();
        window.webkit.messageHandlers.sbPicker.postMessage({
          event: 'selected',
          selector: selectorFor(el),
          tag: el.tagName.toLowerCase(),
          text: (el.innerText || '').trim().substring(0, 80),
          width: Math.round(r.width),
          height: Math.round(r.height),
          canExpand: !!(el.parentElement && el !== document.body),
          canContract: !!largestChild(el)
        });
      }

      window.__sbSetCurrent = function(sel) {
        try { window.__sbCurrent = sel ? document.querySelector(sel) : null; }
        catch (e) { window.__sbCurrent = null; }
        report();
      };
      window.__sbExpand = function() {
        var el = window.__sbCurrent;
        if (el && el.parentElement && el !== document.body) {
          window.__sbCurrent = el.parentElement;
        }
        report();
      };
      window.__sbContract = function() {
        var el = window.__sbCurrent;
        var child = el && largestChild(el);
        if (child) { window.__sbCurrent = child; }
        report();
      };
      window.__sbClearCurrent = function() {
        window.__sbCurrent = null;
        outline(chosen, null);
        outline(hover, null);
      };
      // While previewing the clip we must get out of the way entirely —
      // otherwise the selection tint and dimming are mistaken for the result.
      window.__sbSetOverlaysHidden = function(hidden) {
        window.__sbOverlaysHidden = hidden;
        if (hidden) {
          chosen.style.display = 'none';
          hover.style.display = 'none';
        } else if (window.__sbCurrent) {
          outline(chosen, window.__sbCurrent);
        }
      };

      function target(ev) {
        var t = ev.target;
        if (!t || t.nodeType !== 1) { return null; }
        if (t === hover || t === chosen) {
          return document.elementFromPoint(ev.clientX, ev.clientY);
        }
        return t;
      }

      document.addEventListener('mousemove', function(ev) {
        if (window.__sbPickEnabled === false) { outline(hover, null); return; }
        outline(hover, target(ev));
      }, true);

      function pick(ev) {
        if (window.__sbPickEnabled === false) { return; }
        var el = target(ev);
        if (!el) { return; }
        ev.preventDefault();
        ev.stopPropagation();
        window.__sbCurrent = el;
        report();
      }
      document.addEventListener('click', pick, true);
      document.addEventListener('touchend', pick, true);
      document.addEventListener('submit', function(ev) {
        if (window.__sbPickEnabled !== false) { ev.preventDefault(); }
      }, true);

      // Keep outlines glued to the element as the page scrolls or resizes.
      function refresh() {
        if (window.__sbCurrent) { outline(chosen, window.__sbCurrent); }
      }
      window.addEventListener('scroll', refresh, true);
      window.addEventListener('resize', refresh, true);
    })();
    """

    // MARK: - Helpers

    static func jsonString(_ value: String) -> String {
        String(decoding: (try? JSONEncoder().encode([value]))?.dropFirst().dropLast() ?? Data("\"\"".utf8),
               as: UTF8.self)
    }

    static func jsonString(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
