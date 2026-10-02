// Мой маленький мир — платформенный модуль v1
// Подключение в игре:  <script src="/sdk/v1.js" data-app="piko"></script>
// Дальше всё через window.Platform (см. README платформы).
(function(){
  'use strict';
  if (window.Platform) return;

  const CFG = {
    SUPABASE_URL: 'https://zykuquspmtmfcaofebxx.supabase.co',
    SUPABASE_KEY: 'sb_publishable_TVLSOeplGZ8na5tmiw_KJA_E5v9fAdU',
    // служебный домен для логинов: почта не используется, логин → u<hex>@домен.
    // Остался от Пико, менять нельзя — иначе старые аккаунты не войдут.
    LOGIN_DOMAIN: 'players.pikogame.app',
    STORAGE_KEY: 'mlymir-auth',
    LEGACY_KEYS: ['piko-auth']
  };

  const me = document.currentScript;
  const APP = (me && me.dataset.app) || 'platform';
  const BASE = me && me.src ? new URL('.', me.src).href : location.origin + '/sdk/';
  const LOCAL = !/^https?:$/.test(location.protocol) || /^(localhost|127\.|\[::1\])/.test(location.hostname);
  const SB_URL = LOCAL ? CFG.SUPABASE_URL : location.origin + '/sb';

  const LS = {
    get(k){ try { return localStorage.getItem(k); } catch(e){ return null; } },
    set(k, v){ try { localStorage.setItem(k, v); } catch(e){} }
  };

  // Сессия из старого ключа Пико переезжает в общий
  if (!LS.get(CFG.STORAGE_KEY)) for (const k of CFG.LEGACY_KEYS){ const v = LS.get(k); if (v){ LS.set(CFG.STORAGE_KEY, v); break; } }

  let sb = null, user = null;
  const subs = new Set();
  const view = u => u ? { id: u.id, username: (u.user_metadata && u.user_metadata.username) || '' } : null;
  function setUser(u){
    const next = view(u), prev = user;
    user = next;
    if ((prev && prev.id) !== (next && next.id) || (prev && prev.username) !== (next && next.username)) subs.forEach(fn => { try { fn(user); } catch(e){ console.error(e); } });
  }

  function loadLib(){
    if (window.supabase) return Promise.resolve();
    return new Promise((res, rej) => {
      const s = document.createElement('script'); s.src = BASE + 'supabase.js';
      s.onload = res; s.onerror = () => rej(new Error('supabase.js не загрузился'));
      document.head.appendChild(s);
    });
  }

  const ready = loadLib().then(async () => {
    sb = window.supabase.createClient(SB_URL, CFG.SUPABASE_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, storageKey: CFG.STORAGE_KEY }
    });
    try { const { data } = await sb.auth.getSession(); setUser(data && data.session && data.session.user); } catch(e){}
    sb.auth.onAuthStateChange((_e, s) => setUser(s && s.user));
    // вход/выход в другой вкладке (витрина ↔ игра)
    window.addEventListener('storage', e => {
      if (e.key !== CFG.STORAGE_KEY) return;
      let u = null; try { u = e.newValue && JSON.parse(e.newValue).user; } catch(_){}
      setUser(u);
    });
    return user;
  }).catch(e => { console.warn('[platform]', e); return null; });

  // ---------- логин → служебный email ----------
  const LOGIN_RE = /^[\p{L}\d_.-]{3,15}$/u;
  function toEmail(u){
    const hex = [...new TextEncoder().encode(u.trim().toLowerCase())].map(b => b.toString(16).padStart(2, '0')).join('');
    return 'u' + hex + '@' + CFG.LOGIN_DOMAIN;
  }
  function errText(e){
    const m = ((e && (e.message || e.error_description || e.msg)) || '').toLowerCase();
    if (m.includes('already registered') || m.includes('already exists') || m.includes('duplicate')) return 'Этот логин уже занят — придумай другой';
    if (m.includes('invalid login') || m.includes('invalid credentials')) return 'Неверный логин или пароль';
    if (m.includes('password') && (m.includes('6') || m.includes('short') || m.includes('weak'))) return 'Пароль слишком простой: минимум 6 символов';
    if (m.includes('fetch') || m.includes('network') || m.includes('load failed') || m.includes('не загрузился')) return 'Нет связи с сервером. Проверь интернет';
    if (m.includes('rate')) return 'Слишком много попыток. Подожди минуту';
    return 'Не получилось: ' + ((e && e.message) || 'неизвестная ошибка');
  }

  async function signUp(login, pass){
    await ready; if (!sb) throw new Error('network');
    const { data, error } = await sb.auth.signUp({ email: toEmail(login), password: pass, options: { data: { username: login } } });
    if (error) throw error;
    if (!data.session) throw new Error('В Supabase включено подтверждение почты');
    // строка игрока; если уже есть — не трогаем
    await sb.from('profiles').upsert({ id: data.user.id, username: login }, { onConflict: 'id', ignoreDuplicates: true });
    setUser(data.user);
    return user;
  }
  async function signIn(login, pass){
    await ready; if (!sb) throw new Error('network');
    const { data, error } = await sb.auth.signInWithPassword({ email: toEmail(login), password: pass });
    if (error) throw error;
    setUser(data.user);
    return user;
  }
  async function logout(){
    await ready;
    try { if (sb) await sb.auth.signOut({ scope: 'local' }); } catch(e){}
    try { localStorage.removeItem(CFG.STORAGE_KEY); } catch(e){}
    setUser(null);
  }

  // ---------- прогресс игры (таблица saves: игрок + игра → данные) ----------
  async function load(){
    await ready; if (!sb || !user) return null;
    const { data, error } = await sb.from('saves').select('data,updated_at').eq('user_id', user.id).eq('app', APP).maybeSingle();
    if (error) throw error;
    return data;                             // { data, updated_at } или null
  }
  async function save(data){
    await ready; if (!sb || !user) throw new Error('не вошёл');
    const now = new Date().toISOString();
    const { error } = await sb.from('saves').upsert({ user_id: user.id, app: APP, data, updated_at: now }, { onConflict: 'user_id,app' });
    if (error) throw error;
    return now;
  }

  // ---------- окно входа ----------
  const DUCK = '<svg viewBox="0 0 64 64" aria-hidden="true"><ellipse cx="32" cy="56" rx="22" ry="3.5" fill="#000" opacity=".12"/><path d="M8 38c0-7 6-11 13-11h6c-3-3-5-6-5-10 0-7 6-12 13-12s13 5 13 12c0 4-2 7-5 9 5 2 9 6 9 12 0 9-9 16-22 16S8 47 8 38z" fill="#ffd23f"/><path d="M12 40c4 7 13 10 22 9 7-1 12-4 14-8-4 3-10 5-17 5-8 0-15-2-19-6z" fill="#f2b705"/><path d="M20 34c3 4 9 6 15 5-2 3-9 4-14 1-2-1-2-4-1-6z" fill="#f2b705"/><path d="M46 19c5-1 10 0 12 2-2 3-7 4-12 3z" fill="#ff8a1f"/><circle cx="40" cy="15" r="2.6" fill="#2b1d0e"/><circle cx="40.9" cy="14.1" r=".9" fill="#fff"/><path d="M22 11c1-6 8-10 15-9 6 1 10 5 10 9-8-2-17-2-25 0z" fill="#e63946"/><path d="M21 11.5c8-2.5 18-2.5 27-.5l-.5 2.5c-8-2-17-2-26 .5z" fill="#b5172a"/><circle cx="34" cy="2.8" r="2.6" fill="#fff"/></svg>';
  const CSS = `
  .mm-ov{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:16px;background:rgba(15,35,48,.55);-webkit-backdrop-filter:blur(3px);backdrop-filter:blur(3px)}
  .mm-ov[hidden]{display:none}
  .mm-card{width:100%;max-width:360px;background:#fffdf6;color:#1f3a4a;border-radius:24px;padding:22px 20px 18px;box-shadow:0 20px 50px -15px rgba(0,0,0,.5);font:600 15px/1.35 'Nunito',system-ui,-apple-system,'Segoe UI',sans-serif;text-align:left}
  .mm-card *{box-sizing:border-box}
  .mm-top{display:flex;align-items:center;gap:12px;margin-bottom:14px}
  .mm-top svg{width:52px;height:52px;flex:none}
  .mm-top small{display:block;color:#4d6b7a;font-size:13px}
  .mm-top b{display:block;font-weight:800;font-size:20px;line-height:1.15}
  .mm-tabs{display:grid;grid-template-columns:1fr 1fr;gap:4px;padding:4px;border-radius:14px;background:#e6f4f8;margin-bottom:14px}
  .mm-tabs button{border:0;border-radius:10px;padding:9px 6px;background:transparent;color:#4d6b7a;font-family:inherit;font-weight:800;font-size:14px;line-height:1;cursor:pointer}
  .mm-tabs button.on{background:#fff;color:#1f3a4a;box-shadow:0 1px 3px rgba(31,58,74,.2)}
  .mm-f label{display:block;font-size:12px;font-weight:800;color:#4d6b7a;margin-bottom:10px}
  .mm-f input{display:block;width:100%;margin-top:4px;font-family:inherit;font-weight:700;font-size:17px;line-height:1.2;padding:12px 14px;border-radius:12px;border:1.5px solid #cfe3ea;background:#fff;color:#1f3a4a;outline:none}
  .mm-f input:focus{border-color:#4aa8c4}
  .mm-err{min-height:18px;margin:2px 0 10px;color:#c62f45;font-size:13px;font-weight:700;text-align:center}
  .mm-row{display:flex;gap:8px}
  .mm-btn{flex:1;border:0;border-radius:999px;padding:12px 14px;font-family:inherit;font-weight:800;font-size:15px;line-height:1;cursor:pointer;background:#e6f4f8;color:#1f3a4a}
  .mm-btn.pri{background:#ffd23f;color:#3a2a00;box-shadow:0 2px 0 #e0a800}
  .mm-btn:disabled{opacity:.6;cursor:default}
  .mm-note{margin:12px 0 0;font-size:12px;color:#4d6b7a;text-align:center}
  `;
  let ov = null, tab = 'login', busy = false, err = '', armed = false, resolveOpen = null;
  const esc = s => String(s || '').replace(/[&<>"]/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c]));

  function mount(){
    if (ov) return;
    const st = document.createElement('style'); st.textContent = CSS; document.head.appendChild(st);
    ov = document.createElement('div'); ov.className = 'mm-ov'; ov.hidden = true;
    ov.innerHTML = '<div class="mm-card" role="dialog" aria-modal="true"></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', onClick);
    ov.addEventListener('keydown', e => { if (e.key === 'Enter' && !user){ e.preventDefault(); submit(); } if (e.key === 'Escape') close(); });
  }
  function render(){
    const card = ov.firstChild;
    if (user){
      card.innerHTML = `<div class="mm-top">${DUCK}<div><small>Мой маленький мир</small><b>Привет, ${esc(user.username)}!</b></div></div>
        <p class="mm-note" style="margin:0 0 14px">Ты вошёл во все игры платформы сразу.</p>
        <div class="mm-row"><button class="mm-btn" data-a="logout">${armed ? 'Точно выйти?' : 'Выйти'}</button><button class="mm-btn pri" data-a="close">Готово</button></div>`;
      return;
    }
    const reg = tab === 'reg';
    card.innerHTML = `<div class="mm-top">${DUCK}<div><small>Мой маленький мир</small><b>${reg ? 'Новый аккаунт' : 'Вход'}</b></div></div>
      <div class="mm-tabs"><button type="button" data-tab="login" class="${reg ? '' : 'on'}">Вход</button><button type="button" data-tab="reg" class="${reg ? 'on' : ''}">Регистрация</button></div>
      <form class="mm-f" onsubmit="return false" autocomplete="on">
        <label>Логин<input data-f="login" name="username" autocomplete="username" autocapitalize="off" autocorrect="off" spellcheck="false" maxlength="15" placeholder="например, pikomaster"></label>
        <label>Пароль<input data-f="pass" name="password" type="password" autocomplete="${reg ? 'new-password' : 'current-password'}" placeholder="минимум 6 символов"></label>
      </form>
      <p class="mm-err">${esc(err)}</p>
      <div class="mm-row"><button class="mm-btn" data-a="close">Позже</button><button class="mm-btn pri" data-a="submit" ${busy ? 'disabled' : ''}>${busy ? 'Секунду…' : reg ? 'Создать' : 'Войти'}</button></div>
      <p class="mm-note">Один аккаунт для всех игр. Логин и пароль из Пико тоже подходят.</p>`;
  }
  const field = n => ov.querySelector(`[data-f="${n}"]`);
  async function submit(){
    if (busy) return;
    const login = (field('login').value || '').trim(), pass = field('pass').value || '';
    const showErr = t => { err = t; ov.querySelector('.mm-err').textContent = t; };
    if (!LOGIN_RE.test(login)) return showErr('Логин: от 3 до 15 букв, цифр, «_», «-» или «.»');
    if (pass.length < 6) return showErr('Пароль: минимум 6 символов');
    busy = true; err = ''; render(); field('login').value = login; field('pass').value = pass;
    try {
      if (tab === 'reg') await signUp(login, pass); else await signIn(login, pass);
      busy = false; close();
    } catch(e){
      busy = false; err = errText(e); render(); field('login').value = login;
    }
  }
  async function onClick(e){
    const t = e.target.closest('[data-tab]'); if (t && !busy){ tab = t.dataset.tab; err = ''; render(); field('login').focus(); return; }
    const a = e.target.closest('[data-a]');
    if (!a){ if (e.target === ov && !busy) close(); return; }
    const act = a.dataset.a;
    if (act === 'close') close();
    else if (act === 'submit') submit();
    else if (act === 'logout'){
      if (!armed){ armed = true; render(); return; }
      await logout(); close();
    }
  }
  function open(mode){
    mount(); armed = false; err = ''; busy = false;
    if (mode === 'reg' || mode === 'login') tab = mode;
    render(); ov.hidden = false;
    const f = !user && field('login'); if (f) setTimeout(() => f.focus(), 30);
    return new Promise(res => { resolveOpen = res; });
  }
  function close(){
    if (!ov) return;
    ov.hidden = true;
    if (resolveOpen){ const r = resolveOpen; resolveOpen = null; r(user); }
  }

  window.Platform = Object.freeze({
    version: 1,
    app: APP,
    ready,                                   // Promise<игрок|null> — когда сессия проверена
    user: () => user,                        // { id, username } или null
    onChange(fn){ subs.add(fn); return () => subs.delete(fn); },  // вход, выход, смена игрока
    login: mode => open(mode),               // окно входа ('login' | 'reg'); для вошедшего — карточка с выходом
    logout,
    load,                                    // прогресс этой игры из облака: { data, updated_at } | null
    save,                                    // сохранить прогресс этой игры, вернёт время сохранения
    get client(){ return sb; }               // клиент Supabase для своих таблиц игры
  });
})();
