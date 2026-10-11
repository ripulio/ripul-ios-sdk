// The native Inspector's DOM provider. Selection is a retained element, never a
// selector re-query: rerendered nodes cannot silently become an action's target.
(() => {
  // A page keeps the engine it was first given. The version lets a newer build
  // replace an older one without a reload.
  if (window.__ripulInspector?.version >= 2) return;
  const elements = new Map();
  const ids = new WeakMap();
  let serial = 0;
  let highlighted = null;
  let savedOutline = null;
  // Where the last pick was, in page coordinates — the point `below` drills through.
  let lastPoint = null;
  const privateSelector = '[data-ripul-context-excluded]';
  const isPrivate = el => {
    for (let current = el; current; current = current.parentElement || current.getRootNode().host) {
      if (current.matches(privateSelector)) return true;
    }
    return false;
  };
  const privateDescendants = el => {
    const result = [...el.querySelectorAll(privateSelector)];
    for (const node of [el, ...el.querySelectorAll('*')]) {
      if (node.shadowRoot) result.push(...privateDescendants(node.shadowRoot));
    }
    return result;
  };
  const key = el => {
    if (!ids.has(el)) { ids.set(el, String(++serial)); elements.set(ids.get(el), new WeakRef(el)); }
    return ids.get(el);
  };
  const get = id => {
    const el = elements.get(id)?.deref();
    if (!el?.isConnected) throw new Error('The selected element was removed. Select it again.');
    return el;
  };
  const rect = el => {
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  };
  const label = el => el.getAttribute('data-ui') || el.id || el.tagName.toLowerCase();
  const summary = el => ({ id: key(el), label: label(el) });
  // A selector something outside the page can find the element with again: an
  // agent given this element and a browser tool. Selection itself stays a
  // retained element. Empty when nothing unique can be written, as inside a
  // shadow tree, which document.querySelector does not reach.
  const selector = el => {
    if (el.getRootNode() !== document) return '';
    const unique = s => { try { return document.querySelectorAll(s).length === 1; } catch { return false; } };
    const quote = s => '"' + s.replace(/["\\]/g, '\\$&') + '"';
    const parts = [];
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      const ui = node.getAttribute('data-ui');
      const anchor = node.id && unique('#' + CSS.escape(node.id)) ? '#' + CSS.escape(node.id)
        : ui && unique('[data-ui=' + quote(ui) + ']') ? '[data-ui=' + quote(ui) + ']'
        : node === document.body ? 'body' : node === document.documentElement ? 'html' : '';
      if (anchor) { parts.unshift(anchor); break; }
      const tag = node.tagName.toLowerCase();
      const same = [...(node.parentElement?.children || [])].filter(c => c.tagName === node.tagName);
      parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
    }
    const result = parts.join(' > ');
    return unique(result) ? result : '';
  };
  const viewport = () => ({ width: visualViewport?.width || innerWidth, height: visualViewport?.height || innerHeight,
    offsetLeft: visualViewport?.offsetLeft || 0, offsetTop: visualViewport?.offsetTop || 0 });
  const boxModel = (el, style) => {
    const sides = (prefix, suffix = '') => Object.fromEntries(
      ['top', 'right', 'bottom', 'left'].map(side =>
        [side, parseFloat(style.getPropertyValue(`${prefix}-${side}${suffix}`)) || 0]));
    const margin = sides('margin'), border = sides('border', '-width'), padding = sides('padding');
    const contentSize = (axis, first, last) => {
      const computed = parseFloat(style.getPropertyValue(axis));
      // Computed dimensions are untransformed CSS pixels. The selection rect
      // is a viewport bounding box and scales/rotates with CSS transforms.
      const size = Number.isFinite(computed) ? computed :
        (axis === 'width' ? el.offsetWidth : el.offsetHeight) ?? el.getBoundingClientRect()[axis];
      const includesEdges = !Number.isFinite(computed) || style.boxSizing === 'border-box';
      return Math.max(0, size - (includesEdges ? border[first] + border[last] + padding[first] + padding[last] : 0));
    };
    return { margin, border, padding, content: {
      width: contentSize('width', 'left', 'right'), height: contentSize('height', 'top', 'bottom')
    } };
  };
  const clear = () => {
    if (highlighted && savedOutline) {
      for (const [name, value, priority] of savedOutline) {
        if (value) highlighted.style.setProperty(name, value, priority);
        else highlighted.style.removeProperty(name);
      }
    }
    highlighted = null; savedOutline = null;
  };
  const inspect = el => {
    const r = rect(el), style = getComputedStyle(el), visible = viewport();
    if (style.visibility === 'hidden' || style.display === 'none' || +style.opacity === 0 || r.width <= 0 || r.height <= 0
        || r.x + r.width <= visible.offsetLeft || r.y + r.height <= visible.offsetTop
        || r.x >= visible.offsetLeft + visible.width || r.y >= visible.offsetTop + visible.height) {
      throw new Error('The selected element is no longer visible. Select it again.');
    }
    const privateSelf = isPrivate(el);
    const privateChildren = privateDescendants(el);
    const text = privateSelf || privateChildren.length ? '' : (el.textContent || '').trim().slice(0, 1500);
    const properties = ['display','position','width','height','box-sizing','padding-top','padding-right','padding-bottom','padding-left',
      'margin-top','margin-right','margin-bottom','margin-left','border-top-width','border-right-width','border-bottom-width',
      'border-left-width','color','background-color','font-size','font-weight','line-height','border-radius','opacity','z-index'];
    const path = []; let parent = el;
    while (parent && path.length < 12) { path.unshift(summary(parent)); parent = parent.parentElement || parent.getRootNode().host; }
    return { id: key(el), label: label(el), tag: el.tagName.toLowerCase(), text,
      identifier: el.getAttribute('data-ui') || el.id || '', role: el.getAttribute('role') || '',
      correlationId: el.closest('[data-correlation-id]')?.getAttribute('data-correlation-id') || '',
      selector: selector(el), page: { url: location.href, title: document.title },
      rect: r, viewport: visible, box: boxModel(el, style),
      styles: Object.fromEntries(properties.map(p => [p, style.getPropertyValue(p)])),
      attributes: Object.fromEntries([...el.attributes].filter(a => !/^(value|style|on)/i.test(a.name)).map(a => [a.name, a.value.slice(0, 500)])),
      ancestors: path.slice(0, -1), children: [...el.children].slice(0, 150).map(summary),
      private: privateSelf, privateRects: privateChildren.map(rect) };
  };
  const show = el => {
    const result = inspect(el);
    if (highlighted !== el) {
      clear(); highlighted = el;
      savedOutline = ['outline','outline-offset'].map(n => [n, el.style.getPropertyValue(n), el.style.getPropertyPriority(n)]);
      el.style.setProperty('outline', '2px solid #ff4081', 'important');
      el.style.setProperty('outline-offset', '-2px', 'important');
    }
    return result;
  };
  window.__ripulInspector = {
    version: 2,
    pickInView(x, y, width) {
      const v = viewport(), scale = v.width / width;
      // Keyboard occlusion changes viewport height without scaling page content.
      return this.pick(x * scale + v.offsetLeft, y * scale + v.offsetTop);
    },
    pick(x, y) {
      lastPoint = { x, y };
      let el = document.elementFromPoint(x, y);
      while (el?.shadowRoot?.elementFromPoint) {
        const next = el.shadowRoot.elementFromPoint(x, y);
        if (!next || next === el) break;
        el = next;
      }
      if (!el) { clear(); return null; }
      return show(el);
    },
    // The next element behind `id` at the last pick point, wrapping to the
    // front. Every element in the stack is a step, ancestors included.
    below(id) {
      if (!lastPoint) throw new Error('Pick an element with the reticule first.');
      const current = get(id);
      const stack = document.elementsFromPoint(lastPoint.x, lastPoint.y);
      if (!stack.length) return null;
      const next = stack[(stack.indexOf(current) + 1) % stack.length];
      return next === current ? null : show(next);
    },
    select: id => show(get(id)),
    read: id => inspect(get(id)),
    clear,
    style(id, property, value) {
      const el = get(id); inspect(el);
      if (value && !CSS.supports(property, value)) throw new Error(`Invalid value for ${property}: ${value}`);
      el.style.setProperty(property, value, 'important');
      return show(el);
    },
    activate(id) {
      const el = get(id); inspect(el);
      if (el.matches('input,textarea,select,[contenteditable="true"]')) el.focus();
      else if (typeof el.click === 'function') el.click();
      else throw new Error('This element cannot be activated.');
      return true;
    },
    async evaluate(id, expression) {
      const el = get(id); inspect(el);
      const value = await new Function('$0', 'return (' + expression + '\n)')(el);
      if (value instanceof Element) return value.outerHTML.slice(0, 12000);
      if (value === undefined) return 'undefined';
      try { return (JSON.stringify(value, null, 2) ?? String(value)).slice(0, 12000); }
      catch { return String(value).slice(0, 12000); }
    }
  };
})();
