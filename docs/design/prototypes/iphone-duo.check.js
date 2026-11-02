/* iPhone Duo 原型的结构校验夹具（配套 iphone-duo-adaptation.md §8）
   用法：打开原型后把 check() 整段贴进控制台执行，或让 agent 用浏览器工具执行它。
   它只读 DOM，不改产品代码；返回的那组计数 + readings 就是 §8 里那几条读数。
   容差 1.5px：设备框与盒子的取整误差。
   九档 = 六个 Duo 姿势 + 三个未知主机档位（800/1280/1920），后三档是今天 rail / 200 侧栏
   两条支路的唯一入口，所以它们也得进扫描；fold 只对 fold!=='unknown' 的档有意义。 */
function check(){
  const poses = ['cover','innerPortrait','innerLandscape','book','laptop','phone','deskNarrow','deskWide','tv'];
  const folds = ['auto','unreachable','forceActive','forceInactive'];
  const TOL = 1.5;
  let combos = 0, frames = 0, boxes = 0, raw = 0, trunc = 0, ratioBad = 0, pmenu = 0, bandLie = 0, itemOver = 0;
  const det = [];
  const readings = {};

  /* 条目自己的盒子有没有被自己的内容顶穿。这里不能用 scrollWidth：inline 元素（`<span>`、`<i>`）
     的 scrollWidth/clientWidth 在 Chrome 里恒为 0，所以「标题被挤成一字一行、竖着顶出条目」
     那种错它量不到——本轮缩放实验台第一版就被这个假绿骗过一次。改成量子元素的底边。 */
  function itemsOverflow(root, tag){
    let n = 0;
    for(const it of root.querySelectorAll('.it, .b')){
      const r = it.getBoundingClientRect();
      if(!r.height) continue;
      for(const ch of it.children){
        const c = ch.getBoundingClientRect();
        if(c.height && c.bottom > r.bottom + TOL){
          n++;
          if(det.length < 8) det.push({kind:'itemOverflow', tag, cls:String(it.className).slice(0,18),
                                       over:Math.round(c.bottom - r.bottom), who:String(ch.className).slice(0,10)});
          break;
        }
      }
    }
    return n;
  }

  for(const f of folds){
    for(const p of poses){
      if(f !== 'auto' && SCREENS[p].fold === 'unknown') continue;   // 未知主机没有带，三种读数同一张图
      STATE.pose = p; STATE.fold = f; STATE.rule = 'both'; render();
      combos++;
      const scrs = document.querySelectorAll('.scr');
      for(let i = 0; i < scrs.length; i++){
        const scr = scrs[i]; frames++;
        const s = scr.getBoundingClientRect();
        const els = scr.querySelectorAll('*');
        for(let j = 0; j < els.length; j++){
          const r = els[j].getBoundingClientRect();
          if(r.width === 0 || r.height === 0) continue;
          boxes++;
          if(r.left < s.left - TOL || r.top < s.top - TOL || r.right > s.right + TOL || r.bottom > s.bottom + TOL){
            raw++;
            if(det.length < 8) det.push({kind:'pastDeviceFrame', fold:f, pose:p, frame:i, cls:String(els[j].className || els[j].tagName).slice(0,20)});
          }
        }
        /* 预算撒谎检查：这条边画不下时靠 overflow:hidden 裁掉，框上看不出来。
           scrollHeight 超过 clientHeight 就是「算出来放得下、画出来放不下」。 */
        for(const bSel of ['.band', '.tpband']){
          const b = scr.querySelector(bSel);
          if(!b) continue;
          if(b.scrollHeight > b.clientHeight + 1.5){
            bandLie++;
            det.push({kind:'bandClipped', fold:f, pose:p, sel:bSel, over:Math.round(b.scrollHeight - b.clientHeight)});
          }
          itemOver += itemsOverflow(b, f + '/' + p + bSel);
        }
        const cds = scr.querySelectorAll('.cd');
        for(let k = 0; k < cds.length; k++){
          const cr = cds[k].getBoundingClientRect();
          const parts = cds[k].querySelectorAll('.tt,.cv');
          for(let q = 0; q < parts.length; q++){
            if(parts[q].getBoundingClientRect().bottom > cr.bottom + 1){
              trunc++;
              if(det.length < 8) det.push({kind:'cutInsideCard', fold:f, pose:p, frame:i, cls:String(parts[q].className).slice(0,20)});
            }
          }
          const cv = cds[k].querySelector('.cv');
          if(cv){
            const b = cv.getBoundingClientRect();
            if(Math.abs(b.height / b.width - 4/3) > 0.02) ratioBad++;
          }
        }
      }
      if(f === 'auto'){
        const cur = env(p,'current'), des = env(p,'both');
        const mp = des.panes === 2 ? masterPane(des) : null;
        const sysLabels = [];
        for(let i = 0; i < scrs.length; i++){
          const sy = scrs[i].querySelector('.band .sys');
          if(!sy) continue;
          const tn = [...sy.childNodes].find(n => n.nodeType === 3 && n.textContent.trim());
          if(!tn) continue;
          const rg = document.createRange(); rg.selectNodeContents(tn);
          const rects = [...rg.getClientRects()];
          sysLabels.push({frame:i, text:tn.textContent.trim(), lineBoxes:rects.length,
            textPx:Math.round(rects[0] ? rects[0].width : 0), bandPx:Math.round(sy.getBoundingClientRect().width)});
        }
        const t0 = gestureModel(cur, false), t1 = gestureModel(des, true);
        readings[p] = {
          todayColumns: cur.columns, designedColumns: des.columns,
          gridAvail: [Math.round(cur.gridAvail), Math.round(des.gridAvail)],
          cellExtent: [cur.cellExtent, des.cellExtent], rows: [cur.rows, des.rows],
          bars: [cur.bars, des.bars], panes: [cur.panes, des.panes],
          masterPane: mp ? {wPt:Math.round(mp.wPt), hPt:Math.round(mp.hPt), columns:mp.cols, demoRows:mp.rows} : null,
          gesture: {
            edge:[Math.round(t0.edge), Math.round(t1.edge)],
            side:[t0.lead ? 'lead' : t0.trail ? 'trail' : 'none', t1.lead ? 'lead' : t1.trail ? 'trail' : 'none'],
            contentW:[Math.round(t0.contentW), Math.round(t1.contentW)],
            paneW:[Math.round(t0.paneW), Math.round(t1.paneW)],
            picW:[Math.round(t0.pic.w), Math.round(t1.pic.w)],
            mid:[Math.round(t0.mid), Math.round(t1.mid)],
            crosses:{todayEp:t0.epCross, designEp:t1.epCross, todayMid:t0.midCross, designMid:t1.midCross,
                     todayPager:t0.pagerCross, designPager:t1.pagerCross, designSearchOver:t1.seOver}
          },
          bandAndGutter: [...scrs].map(scr => [...scr.querySelectorAll('.band,.gutter')].map(el => {
            const r = el.getBoundingClientRect(), s = scr.getBoundingClientRect();
            return {cls:String(el.className), w:Math.round(r.width), h:Math.round(r.height),
                    x:Math.round(r.left - s.left), y:Math.round(r.top - s.top)};
          })).filter(a => a.length),
          sysLabels
        };
      }
    }
  }

  /* 第 4 节溢出菜单：点开的态也要扫一遍（.pmenu 是绝对定位，最容易顶出容器） */
  const menuHosts = [];
  for(const p of poses){
    STATE.pose = p; STATE.fold = 'auto'; STATE.rule = 'both'; STATE.menu = true; render();
    const m = document.querySelector('#menuHost .pmenu');
    if(!m) continue;
    pmenu++;
    const host = m.parentElement.getBoundingClientRect(), mr = m.getBoundingClientRect();
    const hItems = m.querySelectorAll('.mi').length;
    if(mr.right > host.right + TOL || mr.left < host.left - TOL)
      det.push({kind:'menuPastHost', pose:p, menu:Math.round(mr.width)});
    menuHosts.push({pose:p, items:hItems, w:Math.round(mr.width), vw:Math.round(window.innerWidth)});
  }
  STATE.menu = false;

  /* 侧栏贴哪一边：外屏实测 safeAreaInsets.right=84，所以 bars==='side' 的格子
     那条 .band 必须贴在屏的右边缘（本轮把它从左边改到右边，这条是防回归）。 */
  const bandEdge = [];
  for(const p of poses){
    STATE.pose = p; STATE.fold = 'auto'; STATE.rule = 'designed'; render();
    for(const scr of document.querySelectorAll('.scr')){
      const b = scr.querySelector(':scope > .band');
      if(!b) continue;
      const r = b.getBoundingClientRect(), s = scr.getBoundingClientRect();
      bandEdge.push({pose:p, gapRight:Math.round(s.right - r.right), gapLeft:Math.round(r.left - s.left)});
      if(Math.abs(s.right - r.right) > TOL) det.push({kind:'bandNotTrailing', pose:p, gap:Math.round(s.right - r.right)});
    }
  }

  /* 第 6 节缩放：滑杆 1.00–1.70 全扫，量两件事——
     ① 侧栏假条不能吃超过屏宽（否则那一格画在设备框外）；
     ② 大字号下标题不许被裁（scrollWidth 不得超过 clientWidth）。 */
  const scaleSweep = [];
  for(const p of ['cover','innerPortrait','innerLandscape','deskNarrow']){
    STATE.pose = p; STATE.fold = 'auto'; STATE.rule = 'designed';
    for(let v = 100; v <= 170; v += 5){
      const el = document.getElementById('s'); el.value = String(v);
      renderScale();
      const scrPx = SCREENS[p].w * PT;
      const host = document.getElementById('scaleHost');
      const band = host.querySelector('.fake-band');
      const bw = band ? band.getBoundingClientRect().width : 0;
      /* 「标题在缩放后还摆得下两行」就是 §5.11 那条预算的全部内容，所以量的是每个条目
         自己的内容底边有没有顶穿条目盒；inline 元素的 scrollWidth 恒为 0，量不到这件事。 */
      const clipped = itemsOverflow(host, 'scale/' + p + '/' + (v / 100));
      itemOver += clipped;
      if(band && band.scrollHeight > band.clientHeight + 1.5){
        bandLie++;
        det.push({kind:'scaleBandClipped', pose:p, s:v / 100, over:Math.round(band.scrollHeight - band.clientHeight)});
      }
      scaleSweep.push({pose:p, s:v/100, bandPx:Math.round(bw), screenPx:Math.round(scrPx),
                       past:Math.round(bw - scrPx), clipped});
      if(bw > scrPx + TOL) det.push({kind:'scaleBandPastScreen', pose:p, s:v/100, px:Math.round(bw)});
    }
  }
  document.getElementById('s').value = '100';

  /* 第 4 节滑杆全扫：90pt 那一端是故意让「连核心四项都放不下」露出来的，
     所以只在预算说放得下（!coreOverrun）时要求画出来也放得下。 */
  const benchSweep = [];
  for(let v = 90; v <= 620; v += 10){
    document.getElementById('h').value = String(v);
    renderBench();
    const fb = document.getElementById('fakeBand');
    const r = computeDrop(v, {sys:true, labels:BAND_GROUPS.length, ovf:true});
    benchSweep.push({avail:v, kept:r.keptCount, usable:Math.round(r.usable), coreOverrun:r.coreOverrun,
                     scroll:fb.scrollHeight, client:fb.clientHeight});
    if(!r.coreOverrun && fb.scrollHeight > fb.clientHeight + 1.5)
      det.push({kind:'benchBandClipped', avail:v, over:Math.round(fb.scrollHeight - fb.clientHeight)});
    itemOver += itemsOverflow(fb, 'bench/' + v);
  }
  document.getElementById('h').value = '560';

  for(const rule of ['current','both']){
    for(const p of poses){ STATE.pose = p; STATE.rule = rule; render(); }
  }
  const txt = document.body.innerText;
  const badTokens = ['undefined','NaN','[object Object]'].filter(b => txt.includes(b));

  STATE.pose = 'cover'; STATE.fold = 'auto'; STATE.rule = 'both'; render();
  return {combos, frames, boxes, pastDeviceFrame:raw, cutInsideCard:trunc, posterRatioBad:ratioBad,
          pmenu, bandLie, itemOver, bandEdge, scaleSweep, benchSweep, menuHosts, badTokens, det, readings};
}
