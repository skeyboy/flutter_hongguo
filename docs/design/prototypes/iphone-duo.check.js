/* iPhone Duo 原型的结构校验夹具（配套 iphone-duo-adaptation.md §8）
   用法：打开原型后把 check() 整段贴进控制台执行，或让 agent 用浏览器工具执行它。
   它只读 DOM，不改产品代码；返回的四个计数 + readings 就是 §8 里那几条读数。
   容差 1.5px：设备框与盒子的取整误差。 */
function check(){
  const poses = ['cover','innerPortrait','innerLandscape','book','laptop','phone'];
  const folds = ['auto','unreachable','forceActive','forceInactive'];
  const TOL = 1.5;
  let combos = 0, frames = 0, boxes = 0, raw = 0, trunc = 0, ratioBad = 0;
  const det = [];
  const readings = {};

  for(const f of folds){
    for(const p of poses){
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
        readings[p] = {
          todayColumns: cur.columns, designedColumns: des.columns,
          gridAvail: [Math.round(cur.gridAvail), Math.round(des.gridAvail)],
          cellExtent: [cur.cellExtent, des.cellExtent], rows: [cur.rows, des.rows],
          bars: [cur.bars, des.bars], panes: [cur.panes, des.panes],
          masterPane: mp ? {wPt:Math.round(mp.wPt), hPt:Math.round(mp.hPt), columns:mp.cols, demoRows:mp.rows} : null,
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

  for(const rule of ['current','both']){
    for(const p of poses){ STATE.pose = p; STATE.rule = rule; render(); }
  }
  const txt = document.body.innerText;
  const badTokens = ['undefined','NaN','[object Object]'].filter(b => txt.includes(b));

  STATE.pose = 'cover'; STATE.fold = 'auto'; STATE.rule = 'both'; render();
  return {combos, frames, boxes, pastDeviceFrame:raw, cutInsideCard:trunc, posterRatioBad:ratioBad, badTokens, det, readings};
}
