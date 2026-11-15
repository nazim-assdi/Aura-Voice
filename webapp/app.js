(() => {
  'use strict';

  const API_BASE = 'https://aura-voice-api.onrender.com';
  const $ = (id) => document.getElementById(id);
  const state = {
    health: null,
    capabilities: {},
    user: null,
    voices: [],
    voiceCache: new Map(),
    favorites: new Map(),
    projects: [],
    projectId: null,
    currentAudioUrl: null,
    currentBlob: null,
    currentFormat: 'wav',
    generatedAudio: null,
    editor: { source: null, blob: null, url: null, duration: 0, buffer: null },
    dubbing: { blob: null, url: null },
    realtime: { active: false, stream: null, audioContext: null, processor: null, sttSocket: null, ttsSocket: null, history: [], busy: false },
    generating: false,
    cartesiaModulePromise: null,
    authMode: 'login',
    toastTimer: null
  };

  const templates = {
    welcome: {
      name: 'Welcome intro', language: 'en',
      text: 'Welcome to Aura Voice Studio. Turn your ideas into clear, natural and expressive speech. Shape your sound, find your voice, and bring every word to life.'
    },
    narration: {
      name: 'Narration', language: 'en',
      text: 'A great story is more than a sequence of words. It is a feeling, a moment, and a voice that carries the listener somewhere new.'
    },
    promo: {
      name: 'Product promo', language: 'en',
      text: 'Meet a smarter way to create. Designed for clarity, crafted for quality, and ready whenever inspiration strikes. Discover what your words can become.'
    },
    bangla: {
      name: 'বাংলা বক্তব্য', language: 'bn',
      text: 'স্বাগতম। আপনার কথাকে আরও সুন্দর, স্পষ্ট ও প্রাণবন্ত কণ্ঠে প্রকাশ করুন। সঠিক ভাষা, পছন্দের কণ্ঠ এবং স্বাভাবিক আবেগ—সবকিছু এক জায়গায়।'
    }
  };

  function showToast(message, isError) {
    const node = $('toast');
    if (!node) return;
    node.textContent = message;
    node.classList.toggle('error', Boolean(isError));
    node.classList.add('show');
    window.clearTimeout(state.toastTimer);
    state.toastTimer = window.setTimeout(() => node.classList.remove('show'), 3400);
  }

  function setNotice(message, kind) {
    const node = $('noticeBar');
    if (!node) return;
    node.textContent = message || '';
    node.className = 'notice-bar';
    if (kind) node.classList.add(kind);
  }

  function setModuleNotice(id, message, kind) {
    const node = $(id);
    if (!node) return;
    node.textContent = message || '';
    node.className = 'notice-bar';
    if (kind) node.classList.add(kind);
  }

  function formatLanguageLabel(code) {
    const labels = { en: 'English', bn: 'বাংলা', ar: 'العربية', hi: 'हिन्दी', auto: 'Auto detect' };
    return labels[code] || code || 'Unknown';
  }

  function selectedFormat() {
    const item = document.querySelector('input[name="format"]:checked');
    return item ? item.value : 'wav';
  }

  function updateFormatSelection() {
    state.currentFormat = selectedFormat();
    document.querySelectorAll('.format-option').forEach((label) => {
      const input = label.querySelector('input');
      label.classList.toggle('selected', Boolean(input && input.value === state.currentFormat));
    });
  }

  function updateCharacterCount() {
    const text = $('scriptText');
    if (!text) return;
    $('charCount').textContent = text.value.length.toLocaleString();
    $('generateButton').disabled = state.generating || text.value.trim().length === 0 || text.value.length > 5000;
  }

  async function rawRequest(pathname, options) {
    const opts = options || {};
    const headers = Object.assign({ Accept: 'application/json' }, opts.headers || {});
    const fetchOptions = {
      method: opts.method || 'GET',
      headers: headers,
      credentials: 'include',
      cache: 'no-store',
      body: opts.body
    };
    const response = await fetch(API_BASE + pathname, fetchOptions);
    return response;
  }

  async function parseResponse(response, expected) {
    if (response.status === 204) return null;
    const type = response.headers.get('content-type') || '';
    if (expected === 'blob') {
      if (!response.ok) {
        let errorText = 'Request failed (' + response.status + ')';
        try {
          const data = await response.json();
          errorText = explainError(data, errorText);
        } catch (_) {}
        throw new Error(errorText);
      }
      return response.blob();
    }
    if (type.indexOf('application/json') >= 0) {
      const data = await response.json();
      if (!response.ok) throw new Error(explainError(data, 'Request failed (' + response.status + ')'));
      return data;
    }
    const text = await response.text();
    if (!response.ok) throw new Error(text || 'Request failed (' + response.status + ')');
    return text;
  }

  function explainError(data, fallback) {
    if (data && typeof data === 'object') {
      const detail = data.detail;
      if (typeof detail === 'string') return detail;
      if (detail && typeof detail === 'object') return detail.message || detail.code || fallback;
      if (data.message) return data.message;
    }
    return fallback;
  }

  async function authenticatedRawRequest(pathname, options, retried) {
    const opts = options || {};
    let response;
    try {
      response = await rawRequest(pathname, opts);
    } catch (error) {
      throw new Error('Could not reach Aura Voice API. Check your connection and try again.');
    }
    if (response.status === 401 && !retried && pathname !== '/api/v1/auth/login' &&
        pathname !== '/api/v1/auth/register' && pathname !== '/api/v1/auth/refresh') {
      let refreshed = false;
      try {
        const refreshResponse = await rawRequest('/api/v1/auth/refresh', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({})
        });
        refreshed = refreshResponse.ok;
      } catch (_) {}
      if (refreshed) return authenticatedRawRequest(pathname, opts, true);
    }
    return response;
  }

  async function request(pathname, options, retried) {
    const opts = options || {};
    const response = await authenticatedRawRequest(pathname, opts, retried);
    return parseResponse(response, opts.responseType);
  }

  function showAuthGate(mode, warning) {
    state.authMode = mode || 'login';
    const gate = $('authGate');
    if (!gate) return;
    gate.classList.remove('hidden');
    gate.setAttribute('aria-hidden', 'false');
    $('authTitle').innerHTML = state.authMode === 'register'
      ? 'Create your account<span class="heading-period">.</span>'
      : 'Welcome back<span class="heading-period">.</span>';
    $('authEyebrow').textContent = state.authMode === 'register' ? 'START YOUR PRIVATE WORKSPACE' : 'YOUR PRIVATE AUDIO SPACE';
    $('authSubtitle').textContent = state.authMode === 'register'
      ? 'Create a secure account to save projects, generated audio and voice preferences.'
      : 'Sign in to access your projects, voice tools and private audio library.';
    $('authNameField').classList.toggle('hidden', state.authMode !== 'register');
    $('authPassword').autocomplete = state.authMode === 'register' ? 'new-password' : 'current-password';
    $('authPassword').minLength = state.authMode === 'register' ? 10 : 1;
    $('authPassword').placeholder = state.authMode === 'register' ? 'At least 10 characters' : 'Your password';
    $('authSubmit').textContent = state.authMode === 'register' ? 'Create secure account →' : 'Sign in securely →';
    $('authSwitchText').textContent = state.authMode === 'register' ? 'Already have an account?' : 'New to Aura Voice?';
    $('authSwitch').textContent = state.authMode === 'register' ? 'Sign in' : 'Create an account';
    const note = $('authServiceWarning');
    if (warning) {
      note.textContent = warning;
      note.classList.remove('hidden');
    } else {
      note.classList.add('hidden');
      note.textContent = '';
    }
    $('authNotice').textContent = '';
    $('authNotice').className = 'notice-bar';
    $('authSubmit').disabled = !state.health || state.health.auth_ready !== true;
    if (state.health && state.health.auth_ready !== true) {
      const message = 'Secure accounts are currently locked because this backend has no durable production database and JWT secret configured. No project or audio can be saved to a private cloud account yet.';
      note.textContent = message;
      note.classList.remove('hidden');
    }
  }

  function hideAuthGate() {
    const gate = $('authGate');
    gate.classList.add('hidden');
    gate.setAttribute('aria-hidden', 'true');
  }

  async function submitAuth(event) {
    event.preventDefault();
    const isRegister = state.authMode === 'register';
    const payload = {
      email: $('authEmail').value.trim(),
      password: $('authPassword').value
    };
    if (isRegister) {
      payload.display_name = $('authName').value.trim();
      if (payload.password.length < 10) {
        $('authNotice').textContent = 'Use a password with at least 10 characters.';
        $('authNotice').className = 'notice-bar error';
        return;
      }
    }
    $('authSubmit').disabled = true;
    $('authSubmit').textContent = isRegister ? 'Creating account…' : 'Signing in…';
    $('authNotice').textContent = 'Connecting securely…';
    $('authNotice').className = 'notice-bar';
    try {
      const user = await request('/api/v1/auth/' + (isRegister ? 'register' : 'login'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      state.user = user;
      hideAuthGate();
      await afterAuthentication();
      showToast(isRegister ? 'Your Aura account is ready.' : 'Welcome back.');
    } catch (error) {
      $('authNotice').textContent = error.message;
      $('authNotice').className = 'notice-bar error';
    } finally {
      $('authSubmit').disabled = !state.health || state.health.auth_ready !== true;
      $('authSubmit').textContent = isRegister ? 'Create secure account →' : 'Sign in securely →';
    }
  }

  async function checkHealth() {
    try {
      const health = await request('/health', { timeout: 12000 });
      state.health = health;
      const caps = await request('/api/v1/capabilities', { timeout: 12000 }).catch(() => ({}));
      state.capabilities = caps || {};
      renderHealth();
      return health;
    } catch (_) {
      state.health = { ok: false, speech_ready: false, database_ready: false, auth_ready: false };
      state.capabilities = {};
      renderHealth();
      return state.health;
    }
  }

  function renderHealth() {
    const h = state.health || {};
    const online = h.ok === true;
    const configured = h.speech_ready === true;
    const authReady = h.auth_ready === true;
    $('engineDot').className = 'engine-dot ' + (online ? (configured ? 'online' : '') : 'offline');
    $('topStatusDot').className = 'status-pulse ' + (online ? 'online' : 'offline');
    $('sidebarEngine').textContent = !online ? 'API unavailable' : configured ? 'Cartesia configured' : 'API online';
    $('sidebarEngineNote').textContent = !online
      ? 'Could not reach the backend'
      : !authReady ? 'Production database setup required' : configured ? 'Speech provider key is present' : 'Cartesia API key is required';
    $('topStatusText').textContent = !online ? 'API offline' : !authReady ? 'Secure setup required' : configured ? 'Engine configured' : 'API online';
    $('settingsStatusDot').className = 'status-pulse ' + (online ? 'online' : 'offline');
    $('settingsApiStatus').textContent = online ? 'Online' : 'Unavailable';
    $('settingsApiStatus').style.color = online ? 'var(--mint)' : 'var(--danger)';
    $('settingsProvider').textContent = h.speech_provider || 'Not configured';
    $('settingsVersion').textContent = h.version || '—';
    $('settingsPlan').textContent = state.user ? (state.user.plan || 'free').toUpperCase() : 'Sign in required';
  }

  async function ensureAuthenticated() {
    const h = state.health || await checkHealth();
    if (h.auth_ready !== true) {
      showAuthGate('login');
      $('authSubmit').disabled = true;
      return false;
    }
    try {
      state.user = await request('/api/v1/auth/me');
      hideAuthGate();
      return true;
    } catch (error) {
      state.user = null;
      if (error.message && error.message.indexOf('auth_not_configured') >= 0) {
        showAuthGate('login', error.message);
      } else {
        showAuthGate('login');
      }
      return false;
    }
  }

  async function afterAuthentication() {
    renderHealth();
    await Promise.all([
      loadVoices($('languageSelect').value, true),
      loadFavorites(),
      loadProjects(),
      loadUsage(),
      loadUserSessions()
    ]);
    const language = $('languageSelect').value;
    $('voiceLanguageFilter').value = language;
    if ($('realtimeLanguage')) $('realtimeLanguage').value = 'en';
    await loadRealtimeVoices();
  }

  async function logout(all) {
    try {
      await request(all ? '/api/v1/auth/logout-all' : '/api/v1/auth/logout', { method: 'POST' });
    } catch (_) {}
    state.user = null;
    state.projectId = null;
    state.projects = [];
    renderHistory();
    showAuthGate('login');
    showToast(all ? 'All sessions signed out.' : 'Signed out.');
  }

  async function changeAccountPassword() {
    const currentPassword = $('currentPassword').value;
    const newPassword = $('newPassword').value;
    const notice = $('accountSecurityNotice');
    if (!currentPassword || newPassword.length < 10) {
      setModuleNotice(
        'accountSecurityNotice',
        'Enter your current password and a new password of at least 10 characters.',
        'error'
      );
      return;
    }
    $('changePasswordButton').disabled = true;
    $('changePasswordButton').textContent = 'Updating password…';
    try {
      await request('/api/v1/auth/password/change', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          current_password: currentPassword,
          new_password: newPassword
        })
      });
      $('currentPassword').value = '';
      $('newPassword').value = '';
      setModuleNotice(
        'accountSecurityNotice',
        'Password changed. Other active sessions have been signed out.',
        'success'
      );
      await loadUserSessions();
      showToast('Password updated securely');
    } catch (error) {
      setModuleNotice('accountSecurityNotice', error.message, 'error');
    } finally {
      $('changePasswordButton').disabled = false;
      $('changePasswordButton').textContent = 'Change password';
    }
  }

  async function permanentlyDeleteAccount() {
    const password = $('deleteAccountPassword').value;
    if (!password) {
      setModuleNotice('accountSecurityNotice', 'Enter your password to confirm account deletion.', 'error');
      return;
    }
    const confirmed = window.confirm(
      'Permanently delete your Aura Voice account, projects and saved audio? This cannot be undone.'
    );
    if (!confirmed) return;

    $('deleteAccountButton').disabled = true;
    $('deleteAccountButton').textContent = 'Deleting account…';
    try {
      await request('/api/v1/auth/account', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password })
      });
      stopRealtime();
      state.user = null;
      state.projectId = null;
      state.projects = [];
      state.favorites.clear();
      $('deleteAccountPassword').value = '';
      renderProjects();
      showAuthGate('register');
      setModuleNotice('accountSecurityNotice', 'Your account and private workspace have been deleted.', 'success');
      showToast('Account deleted');
    } catch (error) {
      setModuleNotice('accountSecurityNotice', error.message, 'error');
    } finally {
      $('deleteAccountButton').disabled = false;
      $('deleteAccountButton').textContent = 'Permanently delete account';
    }
  }

  function makeVoiceOption(voice) {
    const option = document.createElement('option');
    option.value = voice.id;
    const suffix = voice.tagline ? ' — ' + voice.tagline : '';
    option.textContent = (voice.name || 'Unnamed voice') + suffix;
    return option;
  }

  async function loadVoices(language, force) {
    const select = $('voiceSelect');
    if (!select) return [];
    const note = $('voiceNote');
    select.replaceChildren(new Option('Loading voices…', ''));
    select.disabled = true;
    if (note) note.textContent = 'Loading available voices for ' + formatLanguageLabel(language) + '…';
    if (!force && state.voiceCache.has(language)) {
      state.voices = state.voiceCache.get(language);
      renderVoiceOptions(state.voices);
      return state.voices;
    }
    try {
      const data = await request('/api/v1/speech/voices?language=' + encodeURIComponent(language) + '&limit=100');
      const voices = Array.isArray(data.voices) ? data.voices : [];
      state.voices = voices;
      state.voiceCache.set(language, voices);
      renderVoiceOptions(voices);
      if (note) note.textContent = voices.length
        ? voices.length + ' voices available for ' + formatLanguageLabel(language) + '.'
        : 'No voices were returned for this language.';
      return voices;
    } catch (error) {
      state.voices = [];
      select.replaceChildren(new Option('Voice catalogue unavailable', ''));
      select.disabled = true;
      if (note) note.textContent = error.message || 'Could not load the voice catalogue.';
      if (error.message && error.message.indexOf('auth_not_configured') >= 0) showAuthGate('login', error.message);
      return [];
    }
  }

  function renderVoiceOptions(voices) {
    const select = $('voiceSelect');
    select.replaceChildren();
    if (!voices.length) {
      select.append(new Option('No voices found', ''));
      select.disabled = true;
      return;
    }
    select.append(new Option('Choose a voice', ''));
    voices.forEach((voice) => select.append(makeVoiceOption(voice)));
    select.disabled = false;
    select.value = voices[0].id;
  }

  async function loadFavorites() {
    try {
      const data = await request('/api/v1/voices/favorites');
      state.favorites.clear();
      (data.favorites || []).forEach((item) => state.favorites.set(item.voice_id, item));
      renderVoiceLibrary();
    } catch (_) {}
  }

  async function toggleFavorite(voice, language) {
    try {
      if (state.favorites.has(voice.id)) {
        await request('/api/v1/voices/favorites/' + encodeURIComponent(voice.id), { method: 'DELETE' });
        state.favorites.delete(voice.id);
        showToast('Voice removed from favourites');
      } else {
        await request('/api/v1/voices/favorites', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ voice_id: voice.id, voice_name: voice.name || 'Voice', language: language })
        });
        state.favorites.set(voice.id, voice);
        showToast('Voice saved to favourites');
      }
      renderVoiceLibrary();
    } catch (error) {
      showToast(error.message, true);
    }
  }

  function renderVoiceLibrary() {
    const grid = $('voiceGrid');
    if (!grid) return;
    const query = $('voiceSearch').value.trim().toLowerCase();
    const voices = state.voices.filter((voice) => {
      const haystack = [voice.name, voice.tagline, voice.gender, voice.language].join(' ').toLowerCase();
      return haystack.indexOf(query) >= 0;
    });
    grid.replaceChildren();
    if (!voices.length) {
      const empty = document.createElement('div');
      empty.className = 'library-loading';
      empty.textContent = state.voices.length
        ? 'No matching voices. Try another search.'
        : 'Sign in and configure Cartesia to load the voice catalogue.';
      grid.append(empty);
      return;
    }
    voices.forEach((voice) => {
      const card = document.createElement('article');
      card.className = 'voice-card';
      const top = document.createElement('div');
      top.className = 'voice-card-top';
      const avatar = document.createElement('div');
      avatar.className = 'voice-avatar';
      avatar.textContent = (voice.name || 'V').slice(0, 1).toUpperCase();
      const fav = document.createElement('button');
      fav.className = 'voice-favorite-button';
      fav.type = 'button';
      fav.textContent = state.favorites.has(voice.id) ? '★' : '☆';
      fav.title = state.favorites.has(voice.id) ? 'Remove favourite' : 'Add favourite';
      fav.addEventListener('click', () => toggleFavorite(voice, $('voiceLanguageFilter').value));
      top.append(avatar, fav);
      const title = document.createElement('h3');
      title.textContent = voice.name || 'Unnamed voice';
      const desc = document.createElement('p');
      desc.textContent = voice.tagline || (voice.language || 'Multilingual') + ' voice';
      const tag = document.createElement('span');
      tag.className = 'voice-tag';
      tag.textContent = voice.gender || voice.language || 'Cartesia';
      const use = document.createElement('button');
      use.className = 'secondary-button';
      use.type = 'button';
      use.textContent = 'Use this voice';
      use.addEventListener('click', async () => {
        $('languageSelect').value = $('voiceLanguageFilter').value;
        $('scriptLanguageLabel').textContent = formatLanguageLabel($('languageSelect').value);
        await loadVoices($('languageSelect').value, true);
        $('voiceSelect').value = voice.id;
        navigate('studio');
        showToast((voice.name || 'Voice') + ' selected');
      });
      card.append(top, title, desc, tag, use);
      grid.append(card);
    });
  }

  async function loadVoiceLibrary(language, force) {
    if (force) state.voiceCache.delete(language);
    if (!state.voiceCache.has(language)) await loadVoices(language, force);
    else {
      state.voices = state.voiceCache.get(language);
      renderVoiceOptions(state.voices);
    }
    renderVoiceLibrary();
  }

  function navigate(page) {
    document.querySelectorAll('.page').forEach((node) => node.classList.toggle('active', node.id === 'page-' + page));
    document.querySelectorAll('.nav-item').forEach((node) => node.classList.toggle('active', node.dataset.page === page));
    const names = { studio: 'Studio', voices: 'Voice library', history: 'Projects', settings: 'Settings', dubbing: 'AI dubbing', editor: 'Audio editor', realtime: 'Live conversation' };
    $('breadcrumbCurrent').textContent = names[page] || 'Studio';
    $('sidebar').classList.remove('open');
    if (page === 'voices') {
      $('voiceLanguageFilter').value = $('languageSelect').value;
      loadVoiceLibrary($('voiceLanguageFilter').value, false);
    }
    if (page === 'history') loadProjects();
    if (page === 'dubbing') loadDubbingVoices();
    if (page === 'realtime') loadRealtimeVoices();
  }

  async function loadUsage() {
    try {
      const usage = await request('/api/v1/auth/usage');
      $('settingsPlan').textContent = String(usage.plan || 'free').toUpperCase();
      const storageMb = (Number(usage.audio_storage_bytes || 0) / (1024 * 1024)).toFixed(1);
      $('settingsUsage').textContent = [
        'TTS ' + usage.generations_today + '/' + usage.daily_generation_limit,
        'STT ' + usage.transcriptions_today + '/' + usage.daily_transcription_limit,
        'Translate ' + usage.translations_today + '/' + usage.daily_translation_limit,
        'Live ' + usage.conversations_today + '/' + usage.daily_conversation_limit,
        storageMb + '/100 MB audio',
        usage.active_projects + '/50 projects'
      ].join(' · ');
    } catch (error) {
      $('settingsPlan').textContent = state.user ? String(state.user.plan || 'free').toUpperCase() : 'Sign in required';
      $('settingsUsage').textContent = 'Unavailable';
    }
  }

  async function loadUserSessions() {
    const list = $('sessionList');
    if (!list || !state.user) return;
    list.replaceChildren();
    const loading = document.createElement('div');
    loading.className = 'empty-history';
    loading.textContent = 'Loading active sessions…';
    list.append(loading);
    try {
      const data = await request('/api/v1/auth/sessions');
      list.replaceChildren();
      const sessions = data.sessions || [];
      if (!sessions.length) {
        const empty = document.createElement('div');
        empty.className = 'empty-history';
        empty.textContent = 'No active sessions were found.';
        list.append(empty);
        return;
      }
      sessions.forEach((item) => {
        const row = document.createElement('div');
        row.className = 'session-item';
        const details = document.createElement('div');
        details.className = 'session-details';
        const title = document.createElement('strong');
        title.textContent = item.current ? 'This browser' : 'Signed-in device';
        const sub = document.createElement('small');
        sub.textContent = (item.user_agent || 'Unknown browser') + ' · ' + (item.ip_address || 'IP not available');
        const time = document.createElement('small');
        time.textContent = 'Last active: ' + (item.last_used_at ? new Date(item.last_used_at).toLocaleString() : 'Unknown');
        details.append(title, sub, time);
        const action = document.createElement('button');
        action.className = 'history-delete';
        action.textContent = item.current ? 'Current' : 'Revoke';
        action.disabled = Boolean(item.current);
        action.addEventListener('click', async () => {
          if (!window.confirm('Sign out this device?')) return;
          try {
            await request('/api/v1/auth/sessions/' + encodeURIComponent(item.id), { method: 'DELETE' });
            await loadUserSessions();
            showToast('Session revoked');
          } catch (error) {
            showToast(error.message, true);
          }
        });
        row.append(details, action);
        list.append(row);
      });
    } catch (error) {
      list.replaceChildren();
      const empty = document.createElement('div');
      empty.className = 'empty-history';
      empty.textContent = error.message || 'Could not load sessions.';
      list.append(empty);
    }
  }


  async function ensureProject() {
    if (state.projectId) {
      try {
        const project = await request('/api/v1/projects/' + encodeURIComponent(state.projectId));
        return project;
      } catch (_) {
        state.projectId = null;
      }
    }
    const payload = {
      name: $('projectName').value.trim() || 'Untitled project',
      script: $('scriptText').value,
      language: $('languageSelect').value,
      settings: {
        voice_id: $('voiceSelect').value,
        speed: Number($('speedRange').value),
        volume: Number($('volumeRange').value),
        emotion: $('emotionSelect').value || null,
        audio_format: selectedFormat()
      }
    };
    const project = await request('/api/v1/projects', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    state.projectId = project.id;
    await loadProjects();
    return project;
  }

  async function saveCurrentProject(showMessage) {
    const project = await ensureProject();
    await request('/api/v1/projects/' + encodeURIComponent(project.id), {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: $('projectName').value.trim() || 'Untitled project',
        script: $('scriptText').value,
        language: $('languageSelect').value,
        settings: {
          voice_id: $('voiceSelect').value,
          speed: Number($('speedRange').value),
          volume: Number($('volumeRange').value),
          emotion: $('emotionSelect').value || null,
          audio_format: selectedFormat()
        }
      })
    });
    if (showMessage !== false) showToast('Project saved securely to your account');
    await loadProjects();
    return project;
  }

  async function saveAssetToProject(blob, filename, mediaType) {
    if (!blob) return null;
    const project = await ensureProject();
    const form = new FormData();
    form.append('file', blob, filename);
    const asset = await request('/api/v1/projects/' + encodeURIComponent(project.id) + '/assets', {
      method: 'POST',
      body: form
    });
    await loadProjects();
    return asset;
  }

  async function loadProjects() {
    const list = $('historyList');
    if (!list || !state.user) return;
    list.replaceChildren();
    const loading = document.createElement('div');
    loading.className = 'empty-history';
    loading.textContent = 'Loading your private projects…';
    list.append(loading);
    try {
      const data = await request('/api/v1/projects');
      state.projects = data.projects || [];
      renderProjects();
    } catch (error) {
      list.replaceChildren();
      const empty = document.createElement('div');
      empty.className = 'empty-history';
      empty.textContent = error.message;
      list.append(empty);
    }
  }

  function renderProjects() {
    const list = $('historyList');
    list.replaceChildren();
    if (!state.projects.length) {
      const empty = document.createElement('div');
      empty.className = 'empty-history';
      empty.textContent = 'No cloud projects yet. Save your first script from Voice Studio.';
      list.append(empty);
      return;
    }
    state.projects.forEach((project) => {
      const row = document.createElement('div');
      row.className = 'history-item';
      const info = document.createElement('div');
      info.className = 'history-main';
      const title = document.createElement('strong');
      title.textContent = project.name || 'Untitled project';
      const details = document.createElement('small');
      details.textContent = formatLanguageLabel(project.language) + ' · Updated ' + new Date(project.updated_at || project.created_at).toLocaleString();
      info.append(title, details);
      const actions = document.createElement('div');
      actions.className = 'project-row-actions';
      const open = document.createElement('button');
      open.className = 'history-open';
      open.textContent = 'Open';
      open.addEventListener('click', () => openProject(project.id));
      const del = document.createElement('button');
      del.className = 'history-delete';
      del.textContent = 'Delete';
      del.addEventListener('click', () => deleteProject(project.id));
      actions.append(open, del);
      row.append(info, actions);
      list.append(row);
    });
  }

  async function openProject(id) {
    try {
      const project = await request('/api/v1/projects/' + encodeURIComponent(id));
      state.projectId = project.id;
      $('projectName').value = project.name || 'Untitled project';
      $('scriptText').value = project.script || '';
      $('languageSelect').value = project.language || 'en';
      $('scriptLanguageLabel').textContent = formatLanguageLabel(project.language || 'en');
      const settings = project.settings || {};
      if (settings.speed) $('speedRange').value = settings.speed;
      $('speedValue').textContent = Number(settings.speed || 1).toFixed(1) + '×';
      if (settings.volume) $('volumeRange').value = settings.volume;
      $('volumeValue').textContent = Number(settings.volume || 1).toFixed(1) + '×';
      $('emotionSelect').value = settings.emotion || '';
      const radio = document.querySelector('input[name="format"][value="' + (settings.audio_format || 'wav') + '"]');
      if (radio) radio.checked = true;
      updateFormatSelection();
      updateCharacterCount();
      await loadVoices(project.language || 'en', true);
      if (settings.voice_id) $('voiceSelect').value = settings.voice_id;
      navigate('studio');
      showToast('Project loaded from your private workspace');
    } catch (error) {
      showToast(error.message, true);
    }
  }

  async function deleteProject(id) {
    if (!window.confirm('Delete this project and its saved audio assets?')) return;
    try {
      await request('/api/v1/projects/' + encodeURIComponent(id), { method: 'DELETE' });
      if (state.projectId === id) state.projectId = null;
      await loadProjects();
      showToast('Project deleted');
    } catch (error) {
      showToast(error.message, true);
    }
  }

  async function generateSpeech() {
    const text = $('scriptText').value.trim();
    if (!text) {
      setNotice('Add a script before generating audio.', 'error');
      $('scriptText').focus();
      return;
    }
    if (text.length > 5000) {
      setNotice('Your script is longer than 5,000 characters.', 'error');
      return;
    }
    if (state.generating) return;

    state.generating = true;
    $('generateButton').disabled = true;
    $('generateLabel').textContent = 'Generating audio…';
    $('generateButton').classList.add('loading');
    $('outputEmpty').classList.remove('hidden');
    $('outputEmpty').querySelector('h2').textContent = 'Creating your audio';
    $('outputEmpty').querySelector('p').textContent = 'Keep this page open while your voice is generated.';
    $('outputContent').classList.add('hidden');
    setNotice('Sending your script to Cartesia Sonic…');

    const format = selectedFormat();
    const payload = {
      text: text,
      language: $('languageSelect').value,
      audio_format: format,
      voice_profile_id: $('voiceSelect').value || null,
      speed: Number($('speedRange').value),
      volume: Number($('volumeRange').value),
      emotion: $('emotionSelect').value || null
    };

    try {
      await saveCurrentProject(false);
      const response = await authenticatedRawRequest('/api/v1/speech/generate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: format === 'mp3' ? 'audio/mpeg' : 'audio/wav' },
        body: JSON.stringify(payload)
      });
      if (!response.ok) throw new Error(explainError(await response.json(), 'Speech generation failed (' + response.status + ')'));
      const blob = await response.blob();
      if (!blob.size) throw new Error('The speech provider returned an empty audio file.');
      if (state.currentAudioUrl) URL.revokeObjectURL(state.currentAudioUrl);
      state.currentBlob = blob;
      state.generatedAudio = blob;
      state.currentAudioUrl = URL.createObjectURL(blob);
      state.currentFormat = format;
      $('audioPlayer').src = state.currentAudioUrl;
      $('outputName').textContent = $('projectName').value.trim() || 'Untitled voice project';
      const chosen = state.voices.find((voice) => voice.id === payload.voice_profile_id);
      $('outputMeta').textContent = format.toUpperCase() + ' · ' +
        (chosen ? chosen.name : 'Cartesia Sonic') + ' · ' + formatLanguageLabel(payload.language);
      $('outputFileInfo').textContent = (blob.size / 1024).toFixed(0) + ' KB · Saved to your private project';
      $('outputEmpty').classList.add('hidden');
      $('outputContent').classList.remove('hidden');
      const extension = format;
      await saveAssetToProject(blob, 'voice-output.' + extension, format === 'mp3' ? 'audio/mpeg' : 'audio/wav');
      setNotice('Your audio is ready and saved in your private project.', 'success');
      $('audioPlayer').play().catch(() => {});
      showToast('Voice generated successfully');
      await loadUsage();
    } catch (error) {
      $('outputEmpty').classList.remove('hidden');
      $('outputEmpty').querySelector('h2').textContent = 'Audio could not be generated';
      $('outputEmpty').querySelector('p').textContent = error.message || 'Check your connection and try again.';
      setNotice(error.message || 'Speech generation failed.', 'error');
      showToast(error.message || 'Speech generation failed', true);
    } finally {
      state.generating = false;
      $('generateLabel').textContent = 'Generate voice';
      $('generateButton').classList.remove('loading');
      updateCharacterCount();
    }
  }

  function downloadBlob(blob, filename) {
    if (!blob) {
      showToast('No audio is available to download.', true);
      return;
    }
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = filename;
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  function downloadAudio() {
    const raw = $('projectName').value.trim() || 'aura-voice';
    const safe = raw.normalize('NFKD').replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').toLowerCase() || 'aura-voice';
    downloadBlob(state.currentBlob, safe + '.' + state.currentFormat);
  }

  function applyTemplate(key) {
    const template = templates[key];
    if (!template) return;
    $('projectName').value = template.name;
    $('scriptText').value = template.text;
    $('languageSelect').value = template.language;
    $('scriptLanguageLabel').textContent = formatLanguageLabel(template.language);
    $('languageSelect').dispatchEvent(new Event('change'));
    updateCharacterCount();
    showToast(template.name + ' template loaded');
  }

  async function loadDubbingVoices() {
    const language = $('dubTargetLanguage').value;
    const select = $('dubVoice');
    select.replaceChildren(new Option('Loading voices…', ''));
    try {
      const data = await request('/api/v1/speech/voices?language=' + encodeURIComponent(language) + '&limit=100');
      const voices = data.voices || [];
      select.replaceChildren();
      if (!voices.length) {
        select.append(new Option('No voices found for this language', ''));
        return;
      }
      voices.forEach((voice) => select.append(new Option(voice.name || 'Voice', voice.id)));
      select.value = voices[0].id;
    } catch (error) {
      select.replaceChildren(new Option('Voice list unavailable', ''));
      setModuleNotice('dubNotice', error.message, 'error');
    }
  }

  async function transcribeDubbing() {
    const file = $('dubFile').files[0];
    if (!file) {
      setModuleNotice('dubNotice', 'Choose an audio file first.', 'error');
      return;
    }
    const form = new FormData();
    form.append('file', file);
    form.append('language', $('dubSourceLanguage').value);
    $('transcribeButton').disabled = true;
    $('transcribeButton').textContent = 'Transcribing…';
    try {
      const data = await request('/api/v1/dubbing/transcribe', { method: 'POST', body: form });
      $('dubTranscript').value = data.text || '';
      setModuleNotice('dubNotice', 'Transcription completed. Review the text before translating.', 'success');
    } catch (error) {
      setModuleNotice('dubNotice', error.message, 'error');
    } finally {
      $('transcribeButton').disabled = false;
      $('transcribeButton').textContent = 'Transcribe audio';
    }
  }

  async function translateDubbing() {
    const text = $('dubTranscript').value.trim();
    if (!text) {
      setModuleNotice('dubNotice', 'Transcribe or enter a source script first.', 'error');
      return;
    }
    $('translateButton').disabled = true;
    $('translateButton').textContent = 'Translating…';
    try {
      const data = await request('/api/v1/dubbing/translate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: text,
          source_language: $('dubSourceLanguage').value,
          target_language: $('dubTargetLanguage').value
        })
      });
      $('dubTranslation').value = data.translated_text || '';
      setModuleNotice('dubNotice', 'Translation ready. Edit if needed and render your new voice track.', 'success');
      await loadDubbingVoices();
    } catch (error) {
      setModuleNotice('dubNotice', error.message, 'error');
    } finally {
      $('translateButton').disabled = false;
      $('translateButton').textContent = 'Translate transcript';
    }
  }

  async function renderDubbing() {
    const text = $('dubTranslation').value.trim();
    const voice = $('dubVoice').value;
    if (!text || !voice) {
      setModuleNotice('dubNotice', 'Add a translated script and select an output voice.', 'error');
      return;
    }
    $('renderDubButton').disabled = true;
    $('renderDubButton').textContent = 'Rendering voice…';
    try {
      const response = await authenticatedRawRequest('/api/v1/dubbing/render', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'audio/wav' },
        body: JSON.stringify({
          translated_text: text,
          target_language: $('dubTargetLanguage').value,
          voice_id: voice,
          audio_format: 'wav'
        })
      });
      if (!response.ok) {
        let errorData = {};
        try { errorData = await response.json(); } catch (_) {}
        throw new Error(explainError(errorData, 'Dubbing render failed (' + response.status + ').'));
      }
      const blob = await response.blob();
      if (!blob.size) throw new Error('The dubbing provider returned an empty audio file.');
      const mediaType = response.headers.get('content-type') || 'audio/wav';
      const format = mediaType.indexOf('mpeg') >= 0 ? 'mp3' : 'wav';
      if (state.dubbing.url) URL.revokeObjectURL(state.dubbing.url);
      state.dubbing.blob = blob;
      state.dubbing.url = URL.createObjectURL(blob);
      $('dubAudioPlayer').src = state.dubbing.url;
      $('dubFileInfo').textContent = (blob.size / 1024).toFixed(0) + ' KB';
      $('dubOutputMeta').textContent = formatLanguageLabel($('dubTargetLanguage').value) + ' · Cartesia Sonic · ' + format.toUpperCase();
      $('dubOutputEmpty').classList.add('hidden');
      $('dubOutputContent').classList.remove('hidden');
      await ensureProject();
      await saveAssetToProject(blob, 'dubbed-track.' + format, mediaType);
      setModuleNotice('dubNotice', 'Dubbing rendered and saved to your private project.', 'success');
      $('dubAudioPlayer').play().catch(() => {});
      await loadUsage();
    } catch (error) {
      setModuleNotice('dubNotice', error.message, 'error');
    } finally {
      $('renderDubButton').disabled = false;
      $('renderDubButton').innerHTML = '<span>✦</span> Render dubbed audio';
    }
  }

  function drawWaveform(buffer) {
    const canvas = $('waveCanvas');
    const context = canvas.getContext('2d');
    const width = canvas.width;
    const height = canvas.height;
    context.clearRect(0, 0, width, height);
    context.strokeStyle = 'rgba(140,242,211,.78)';
    context.lineWidth = 2;
    const channel = buffer.getChannelData(0);
    const step = Math.max(1, Math.floor(channel.length / width));
    const middle = height / 2;
    for (let x = 0; x < width; x += 1) {
      let minimum = 1;
      let maximum = -1;
      const start = x * step;
      for (let j = 0; j < step && start + j < channel.length; j += 1) {
        const value = channel[start + j];
        if (value < minimum) minimum = value;
        if (value > maximum) maximum = value;
      }
      context.beginPath();
      context.moveTo(x, middle - maximum * middle * .88);
      context.lineTo(x, middle - minimum * middle * .88);
      context.stroke();
    }
    $('waveEmpty').classList.add('hidden');
  }

  async function loadEditorFile(file) {
    if (!file) return;
    try {
      const bytes = await file.arrayBuffer();
      const audioContext = new (window.AudioContext || window.webkitAudioContext)();
      const buffer = await audioContext.decodeAudioData(bytes.slice(0));
      await audioContext.close();
      state.editor.source = file;
      state.editor.buffer = buffer;
      state.editor.duration = buffer.duration;
      $('editorSourceName').textContent = file.name + ' · ' + buffer.duration.toFixed(2) + ' seconds';
      $('editorAudioPreview').src = URL.createObjectURL(file);
      ['trimStart', 'trimEnd'].forEach((id) => {
        $(id).max = buffer.duration.toFixed(2);
      });
      $('trimStart').value = '0';
      $('trimEnd').value = buffer.duration.toFixed(2);
      $('trimStartValue').textContent = '0.00 s';
      $('trimEndValue').textContent = buffer.duration.toFixed(2) + ' s';
      drawWaveform(buffer);
      setModuleNotice('editorNotice', 'Audio loaded. Adjust the controls and export a new WAV.', 'success');
    } catch (error) {
      setModuleNotice('editorNotice', 'Could not decode this audio file: ' + error.message, 'error');
    }
  }

  async function useGeneratedInEditor() {
    if (!state.generatedAudio) {
      showToast('Generate speech first, then open it in the editor.', true);
      return;
    }
    const file = new File([state.generatedAudio], 'aura-generated.' + state.currentFormat, {
      type: state.currentFormat === 'mp3' ? 'audio/mpeg' : 'audio/wav'
    });
    await loadEditorFile(file);
  }

  function encodeWav(audioBuffer) {
    const channels = audioBuffer.numberOfChannels;
    const sampleRate = audioBuffer.sampleRate;
    const frames = audioBuffer.length;
    const bytesPerSample = 2;
    const buffer = new ArrayBuffer(44 + frames * channels * bytesPerSample);
    const view = new DataView(buffer);
    function writeText(offset, text) {
      for (let i = 0; i < text.length; i += 1) view.setUint8(offset + i, text.charCodeAt(i));
    }
    writeText(0, 'RIFF');
    view.setUint32(4, 36 + frames * channels * bytesPerSample, true);
    writeText(8, 'WAVE');
    writeText(12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, channels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * channels * bytesPerSample, true);
    view.setUint16(32, channels * bytesPerSample, true);
    view.setUint16(34, 16, true);
    writeText(36, 'data');
    view.setUint32(40, frames * channels * bytesPerSample, true);
    const channelData = [];
    for (let channel = 0; channel < channels; channel += 1) channelData.push(audioBuffer.getChannelData(channel));
    let offset = 44;
    for (let frame = 0; frame < frames; frame += 1) {
      for (let channel = 0; channel < channels; channel += 1) {
        const value = Math.max(-1, Math.min(1, channelData[channel][frame]));
        view.setInt16(offset, value < 0 ? value * 32768 : value * 32767, true);
        offset += 2;
      }
    }
    return new Blob([buffer], { type: 'audio/wav' });
  }

  async function applyAudioEdits() {
    const source = state.editor.buffer;
    if (!source) {
      setModuleNotice('editorNotice', 'Open an audio file first.', 'error');
      return;
    }
    const start = Number($('trimStart').value);
    const end = Number($('trimEnd').value);
    if (end <= start) {
      setModuleNotice('editorNotice', 'Trim end must be greater than trim start.', 'error');
      return;
    }
    const gainValue = Number($('editorGain').value);
    const fadeIn = Math.min(Number($('fadeIn').value), end - start);
    const fadeOut = Math.min(Number($('fadeOut').value), end - start);
    const length = Math.max(1, Math.floor((end - start) * source.sampleRate));
    const offline = new OfflineAudioContext(source.numberOfChannels, length, source.sampleRate);
    const buffer = offline.createBuffer(source.numberOfChannels, length, source.sampleRate);
    for (let channel = 0; channel < source.numberOfChannels; channel += 1) {
      const slice = source.getChannelData(channel).slice(
        Math.floor(start * source.sampleRate),
        Math.floor(start * source.sampleRate) + length
      );
      buffer.copyToChannel(slice, channel);
    }
    const sourceNode = offline.createBufferSource();
    const gain = offline.createGain();
    sourceNode.buffer = buffer;
    gain.gain.setValueAtTime(gainValue, 0);
    if (fadeIn > 0) {
      gain.gain.setValueAtTime(0, 0);
      gain.gain.linearRampToValueAtTime(gainValue, fadeIn);
    }
    if (fadeOut > 0) {
      const fadeStart = Math.max(fadeIn, end - start - fadeOut);
      gain.gain.setValueAtTime(gainValue, fadeStart);
      gain.gain.linearRampToValueAtTime(0, end - start);
    }
    sourceNode.connect(gain);
    gain.connect(offline.destination);
    sourceNode.start(0);
    $('applyEditsButton').disabled = true;
    $('applyEditsButton').textContent = 'Processing…';
    try {
      const rendered = await offline.startRendering();
      const blob = encodeWav(rendered);
      state.editor.blob = blob;
      if (state.editor.url) URL.revokeObjectURL(state.editor.url);
      state.editor.url = URL.createObjectURL(blob);
      $('editorOutputPlayer').src = state.editor.url;
      $('editorOutputMeta').textContent = 'WAV · ' + rendered.sampleRate + ' Hz · ' + rendered.numberOfChannels + ' channel(s)';
      $('editorFileInfo').textContent = (blob.size / 1024).toFixed(0) + ' KB · ' + rendered.duration.toFixed(2) + ' seconds';
      $('editorOutputEmpty').classList.add('hidden');
      $('editorOutputContent').classList.remove('hidden');
      await saveAssetToProject(blob, 'edited-master.wav', 'audio/wav');
      setModuleNotice('editorNotice', 'Edited WAV master exported and saved to your private project.', 'success');
      await loadUsage();
    } catch (error) {
      setModuleNotice('editorNotice', 'Audio processing failed: ' + error.message, 'error');
    } finally {
      $('applyEditsButton').disabled = false;
      $('applyEditsButton').textContent = 'Apply edits & export WAV →';
    }
  }

  function updateEditorLabels() {
    if (state.editor.duration) {
      $('trimStartValue').textContent = Number($('trimStart').value).toFixed(2) + ' s';
      $('trimEndValue').textContent = Number($('trimEnd').value).toFixed(2) + ' s';
    }
    $('editorGainValue').textContent = Math.round(Number($('editorGain').value) * 100) + '%';
    $('fadeInValue').textContent = Number($('fadeIn').value).toFixed(1) + ' s';
    $('fadeOutValue').textContent = Number($('fadeOut').value).toFixed(1) + ' s';
  }

  async function loadRealtimeVoices() {
    const select = $('realtimeVoice');
    if (!select) return;
    try {
      const data = await request('/api/v1/speech/voices?language=en&limit=100');
      const voices = data.voices || [];
      select.replaceChildren();
      if (!voices.length) select.append(new Option('No English voices found', ''));
      else voices.forEach((voice) => select.append(new Option(voice.name || 'Voice', voice.id)));
    } catch (error) {
      select.replaceChildren(new Option('Voice list unavailable', ''));
      setModuleNotice('realtimeNotice', error.message, 'error');
    }
  }

  function appendChat(role, text) {
    const log = $('conversationLog');
    const empty = log.querySelector('.conversation-empty');
    if (empty) empty.remove();
    const bubble = document.createElement('div');
    bubble.className = 'chat-bubble ' + role;
    const label = document.createElement('small');
    label.textContent = role === 'user' ? 'YOU' : 'AURA VOICE';
    const body = document.createElement('div');
    body.textContent = text;
    bubble.append(label, body);
    log.append(bubble);
    log.scrollTop = log.scrollHeight;
    state.realtime.history.push({ role: role === 'user' ? 'user' : 'assistant', content: text });
    state.realtime.history = state.realtime.history.slice(-10);
  }

  async function loadCartesiaSdk() {
    if (!state.cartesiaModulePromise) {
      state.cartesiaModulePromise = import('https://esm.sh/@cartesia/cartesia-js@4.2.0?target=es2022');
    }
    const module = await state.cartesiaModulePromise;
    return module.default || module.Cartesia || module;
  }

  async function streamAssistantSpeech(text) {
    const rt = state.realtime;
    const tokenData = await request('/api/v1/realtime/token', { method: 'POST' });
    const Client = await loadCartesiaSdk();
    const client = new Client({ token: tokenData.token });
    const ws = await client.tts.websocket();
    rt.ttsSocket = ws;
    ws.on('error', (error) => setModuleNotice('realtimeNotice', error.message || 'Cartesia TTS stream error.', 'error'));
    const sampleRate = 44100;
    const voiceId = $('realtimeVoice').value || $('voiceSelect').value;
    const ctx = ws.context({
      model_id: rt.modelId || 'sonic-3.6',
      voice: voiceId,
      output_format: { container: 'raw', encoding: 'pcm_f32le', sample_rate: sampleRate },
      language: $('realtimeLanguage').value
    });
    await ctx.push({ transcript: text });
    await ctx.no_more_inputs();
    if (rt.audioContext && rt.audioContext.state === 'suspended') await rt.audioContext.resume();
    let nextStartTime = rt.audioContext ? rt.audioContext.currentTime : 0;
    try {
      for await (const event of ctx.receive()) {
        if (!rt.active) break;
        if (event.type === 'chunk' && event.audio) {
          const floats = new Float32Array(
            event.audio.buffer,
            event.audio.byteOffset,
            event.audio.byteLength / 4
          );
          const audioContext = rt.audioContext || new AudioContext({ sampleRate });
          const audioBuffer = audioContext.createBuffer(1, floats.length, sampleRate);
          audioBuffer.getChannelData(0).set(floats);
          const source = audioContext.createBufferSource();
          source.buffer = audioBuffer;
          source.connect(audioContext.destination);
          const startAt = Math.max(nextStartTime, audioContext.currentTime + 0.015);
          source.start(startAt);
          nextStartTime = startAt + audioBuffer.duration;
        } else if (event.type === 'error') {
          throw new Error(event.message || event.title || 'Cartesia TTS stream failed.');
        }
      }
    } finally {
      try { ws.close(); } catch (_) {}
      if (rt.ttsSocket === ws) rt.ttsSocket = null;
    }
  }

  async function sendConversationMessage(text) {
    const value = (text || '').trim();
    if (!value || state.realtime.busy) return;
    state.realtime.busy = true;
    appendChat('user', value);
    setModuleNotice('realtimeNotice', 'Aura is preparing a reply…');
    try {
      const data = await request('/api/v1/realtime/respond', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          transcript: value.slice(0, 6000),
          history: state.realtime.history
            .slice(0, -1)
            .slice(-10)
            .map((item) => ({
              role: item.role === 'assistant' ? 'assistant' : 'user',
              content: String(item.content || '').slice(-1200)
            }))
        })
      });
      const reply = data.reply || '';
      appendChat('assistant', reply);
      if (state.realtime.active) {
        $('realtimeStatusTitle').textContent = 'Aura is speaking';
        $('realtimeStatusNote').textContent = 'Streaming Sonic audio in short chunks.';
        await streamAssistantSpeech(reply);
        if (state.realtime.active) {
          $('realtimeStatusTitle').textContent = 'Listening';
          $('realtimeStatusNote').textContent = 'Speak when Aura has finished.';
        }
      } else {
        const voice = $('realtimeVoice').value || $('voiceSelect').value;
        const response = await authenticatedRawRequest('/api/v1/speech/generate', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Accept: 'audio/wav' },
          body: JSON.stringify({
            text: reply,
            language: 'en',
            audio_format: 'wav',
            voice_profile_id: voice || null,
            speed: 1,
            volume: 1
          })
        });
        if (!response.ok) throw new Error(explainError(await response.json(), 'Could not synthesize assistant voice.'));
        const blob = await response.blob();
        const url = URL.createObjectURL(blob);
        const audio = new Audio(url);
        await audio.play().catch(() => {});
        audio.addEventListener('ended', () => URL.revokeObjectURL(url), { once: true });
      }
      setModuleNotice('realtimeNotice', 'Reply ready.', 'success');
    } catch (error) {
      setModuleNotice('realtimeNotice', error.message, 'error');
    } finally {
      state.realtime.busy = false;
    }
  }

  function downsampleTo16k(float32, inputRate) {
    if (inputRate === 16000) return float32;
    const ratio = inputRate / 16000;
    const newLength = Math.floor(float32.length / ratio);
    const result = new Float32Array(newLength);
    let offsetResult = 0;
    let offsetBuffer = 0;
    while (offsetResult < result.length) {
      const nextOffset = Math.floor((offsetResult + 1) * ratio);
      let sum = 0;
      let count = 0;
      for (let i = offsetBuffer; i < nextOffset && i < float32.length; i += 1) {
        sum += float32[i];
        count += 1;
      }
      result[offsetResult] = count ? sum / count : 0;
      offsetResult += 1;
      offsetBuffer = nextOffset;
    }
    return result;
  }

  function floatTo16BitPCM(input) {
    const output = new ArrayBuffer(input.length * 2);
    const view = new DataView(output);
    for (let i = 0; i < input.length; i += 1) {
      const sample = Math.max(-1, Math.min(1, input[i]));
      view.setInt16(i * 2, sample < 0 ? sample * 32768 : sample * 32767, true);
    }
    return output;
  }

  function stopRealtime() {
    const rt = state.realtime;
    rt.active = false;
    if (rt.processor) {
      try { rt.processor.disconnect(); } catch (_) {}
      rt.processor.onaudioprocess = null;
      rt.processor = null;
    }
    if (rt.sttSocket) {
      try { rt.sttSocket.close(); } catch (_) {}
      rt.sttSocket = null;
    }
    if (rt.ttsSocket) {
      try { rt.ttsSocket.close(); } catch (_) {}
      rt.ttsSocket = null;
    }
    if (rt.stream) {
      rt.stream.getTracks().forEach((track) => track.stop());
      rt.stream = null;
    }
    if (rt.audioContext) {
      rt.audioContext.close().catch(() => {});
      rt.audioContext = null;
    }
    rt.pendingAudio = new Float32Array(0);
    $('realtimeOrb').classList.remove('active');
    $('realtimeStatusTitle').textContent = 'Session ended';
    $('realtimeStatusNote').textContent = 'Your microphone has been released.';
    $('startConversationButton').disabled = false;
    $('stopConversationButton').disabled = true;
  }

  async function startRealtime() {
    if (state.realtime.active) return;
    const liveLanguage = $('realtimeLanguage').value;
    if (!['en', 'es', 'fr', 'hi', 'ja'].includes(liveLanguage)) {
      setModuleNotice('realtimeNotice', 'Live Ink-2 recognition currently supports English, Spanish, French, Hindi and Japanese. Choose one of these languages.', 'error');
      return;
    }
    $('startConversationButton').disabled = true;
    setModuleNotice('realtimeNotice', 'Requesting a short-lived Cartesia access token…');
    try {
      const tokenData = await request('/api/v1/realtime/token', { method: 'POST' });
      const Client = await loadCartesiaSdk();
      const client = new Client({ token: tokenData.token });
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
      });
      const rt = state.realtime;
      rt.active = true;
      rt.accessToken = tokenData.token;
      rt.modelId = tokenData.model_id || 'sonic-3.6';
      rt.stream = stream;
      rt.audioContext = new (window.AudioContext || window.webkitAudioContext)();
      if (rt.audioContext.state === 'suspended') await rt.audioContext.resume();

      const source = rt.audioContext.createMediaStreamSource(stream);
      rt.processor = rt.audioContext.createScriptProcessor(4096, 1, 1);
      rt.pendingAudio = new Float32Array(0);
      const inputSampleRate = rt.audioContext.sampleRate;
      const sttSampleRate = 16000;
      const chunkSamples = 1600; // 100 ms at 16 kHz, signed 16-bit PCM
      rt.sttSocket = client.stt.autoFinalize.websocket({
        model: tokenData.stt_model_id || 'ink-2',
        encoding: 'pcm_s16le',
        sample_rate: sttSampleRate,
        language: liveLanguage
      });
      rt.sttSocket.on('error', (error) => {
        setModuleNotice('realtimeNotice', error.message || 'Cartesia STT stream error.', 'error');
      });

      rt.processor.onaudioprocess = (event) => {
        const output = event.outputBuffer;
        for (let channel = 0; channel < output.numberOfChannels; channel += 1) {
          output.getChannelData(channel).fill(0);
        }
        if (!rt.active || rt.busy || !rt.sttSocket) return;
        const incoming = event.inputBuffer.getChannelData(0);
        const resampled = downsampleTo16k(incoming, inputSampleRate);
        const combined = new Float32Array(rt.pendingAudio.length + resampled.length);
        combined.set(rt.pendingAudio, 0);
        combined.set(resampled, rt.pendingAudio.length);
        let offset = 0;
        while (combined.length - offset >= chunkSamples) {
          const chunk = combined.subarray(offset, offset + chunkSamples);
          rt.sttSocket.sendRaw(floatTo16BitPCM(chunk));
          offset += chunkSamples;
        }
        rt.pendingAudio = combined.slice(offset);
      };

      source.connect(rt.processor);
      rt.processor.connect(rt.audioContext.destination);
      $('realtimeOrb').classList.add('active');
      $('realtimeStatusTitle').textContent = 'Listening';
      $('realtimeStatusNote').textContent = 'Speak naturally in ' + formatLanguageLabel(liveLanguage) + '; Ink-2 will detect when your turn ends.';
      $('stopConversationButton').disabled = false;
      $('startConversationButton').disabled = true;

      rt.sttStreamTask = (async () => {
        try {
          for await (const event of rt.sttSocket.stream()) {
            if (!rt.active) break;
            if (event.type === 'error') {
              setModuleNotice('realtimeNotice', event.error && event.error.message ? event.error.message : 'Speech recognition stream failed.', 'error');
              continue;
            }
            if (event.type !== 'message') continue;
            const message = event.message || {};
            if (message.type === 'turn.start') {
              $('realtimeStatusTitle').textContent = 'Hearing you';
            } else if (message.type === 'turn.update' || message.type === 'turn.eager_end') {
              $('realtimeStatusNote').textContent = message.transcript || 'Listening…';
            } else if (message.type === 'turn.end') {
              const transcript = (message.transcript || '').trim();
              if (transcript && !rt.busy) {
                await sendConversationMessage(transcript);
              }
            }
          }
        } catch (error) {
          if (rt.active) setModuleNotice('realtimeNotice', error.message || 'The live speech stream stopped.', 'error');
        }
      })();
      setModuleNotice('realtimeNotice', 'Live microphone session is active. Your key remains on the backend.', 'success');
    } catch (error) {
      stopRealtime();
      setModuleNotice('realtimeNotice', error.message || 'Could not start the live voice session.', 'error');
      $('startConversationButton').disabled = false;
    }
  }
  function bindEvents() {
    document.querySelectorAll('.nav-item').forEach((button) => {
      button.addEventListener('click', () => navigate(button.dataset.page));
    });
    $('mobileMenu').addEventListener('click', () => $('sidebar').classList.toggle('open'));
    $('generateButton').addEventListener('click', generateSpeech);
    $('downloadButton').addEventListener('click', downloadAudio);
    $('saveProjectButton').addEventListener('click', () => saveCurrentProject(true).catch((error) => showToast(error.message, true)));
    $('logoutButton').addEventListener('click', () => logout(false));
    $('logoutAllButton').addEventListener('click', () => logout(true));
    $('refreshSessions').addEventListener('click', loadUserSessions);
    $('changePasswordButton').addEventListener('click', changeAccountPassword);
    $('deleteAccountButton').addEventListener('click', permanentlyDeleteAccount);
    $('authForm').addEventListener('submit', submitAuth);
    $('authSwitch').addEventListener('click', () => showAuthGate(state.authMode === 'login' ? 'register' : 'login'));
    $('scriptText').addEventListener('input', updateCharacterCount);
    $('speedRange').addEventListener('input', () => $('speedValue').textContent = Number($('speedRange').value).toFixed(1) + '×');
    $('volumeRange').addEventListener('input', () => $('volumeValue').textContent = Number($('volumeRange').value).toFixed(1) + '×');
    document.querySelectorAll('input[name="format"]').forEach((input) => input.addEventListener('change', updateFormatSelection));
    $('languageSelect').addEventListener('change', () => {
      const language = $('languageSelect').value;
      $('scriptLanguageLabel').textContent = formatLanguageLabel(language);
      $('voiceLanguageFilter').value = language;
      loadVoices(language, true);
    });
    $('refreshVoices').addEventListener('click', () => loadVoices($('languageSelect').value, true));
    $('voicesRefreshPage').addEventListener('click', () => loadVoiceLibrary($('voiceLanguageFilter').value, true));
    $('voiceLanguageFilter').addEventListener('change', () => loadVoiceLibrary($('voiceLanguageFilter').value, true));
    $('voiceSearch').addEventListener('input', renderVoiceLibrary);
    $('retryHealth').addEventListener('click', async () => { await checkHealth(); if (state.user) await loadUsage(); });
    $('settingsReconnect').addEventListener('click', async () => {
      await checkHealth();
      if (state.health && state.health.auth_ready) await ensureAuthenticated();
      showToast('Connection status refreshed');
    });
    $('clearScript').addEventListener('click', () => {
      $('scriptText').value = '';
      updateCharacterCount();
      $('scriptText').focus();
    });
    $('pasteScript').addEventListener('click', async () => {
      try {
        $('scriptText').value = await navigator.clipboard.readText();
        updateCharacterCount();
        showToast('Text pasted');
      } catch (_) { showToast('Clipboard access was blocked by your browser.', true); }
    });
    $('openApiDocs').addEventListener('click', () => window.open(API_BASE + '/docs', '_blank', 'noopener'));
    $('transcribeButton').addEventListener('click', transcribeDubbing);
    $('translateButton').addEventListener('click', translateDubbing);
    $('renderDubButton').addEventListener('click', renderDubbing);
    $('dubTargetLanguage').addEventListener('change', loadDubbingVoices);
    $('downloadDubButton').addEventListener('click', () => downloadBlob(state.dubbing.blob, 'aura-dub.' + (state.dubbing.blob && state.dubbing.blob.type.indexOf('mpeg') >= 0 ? 'mp3' : 'wav')));
    $('editorFile').addEventListener('change', (event) => loadEditorFile(event.target.files[0]));
    $('editorUseGenerated').addEventListener('click', useGeneratedInEditor);
    ['trimStart', 'trimEnd', 'editorGain', 'fadeIn', 'fadeOut'].forEach((id) => $(id).addEventListener('input', updateEditorLabels));
    $('resetEditor').addEventListener('click', () => {
      const duration = state.editor.duration;
      if (!duration) return;
      $('trimStart').value = '0';
      $('trimEnd').value = duration;
      $('editorGain').value = '1';
      $('fadeIn').value = '0';
      $('fadeOut').value = '0';
      updateEditorLabels();
      setModuleNotice('editorNotice', 'Edit controls reset.', 'success');
    });
    $('applyEditsButton').addEventListener('click', applyAudioEdits);
    $('downloadEditedButton').addEventListener('click', () => downloadBlob(state.editor.blob, 'aura-edited-master.wav'));
    $('startConversationButton').addEventListener('click', startRealtime);
    $('stopConversationButton').addEventListener('click', stopRealtime);
    $('sendRealtimeText').addEventListener('click', () => {
      const input = $('realtimeTextInput');
      const value = input.value;
      input.value = '';
      sendConversationMessage(value);
    });
    $('realtimeTextInput').addEventListener('keydown', (event) => {
      if (event.key === 'Enter') $('sendRealtimeText').click();
    });
    $('clearHistory').addEventListener('click', async () => {
      if (state.projectId) {
        state.projectId = null;
      }
      await loadProjects();
      showToast('Project list refreshed');
    });
    document.querySelectorAll('.template-chip').forEach((button) => {
      button.addEventListener('click', () => applyTemplate(button.dataset.template));
    });
    window.addEventListener('beforeunload', stopRealtime);
  }

  async function init() {
    $('apiEndpoint').textContent = API_BASE;
    bindEvents();
    updateCharacterCount();
    updateFormatSelection();
    updateEditorLabels();
    await checkHealth();
    const authenticated = await ensureAuthenticated();
    if (authenticated) await afterAuthentication();
    else {
      renderProjects();
      $('authSubmit').disabled = !state.health || state.health.auth_ready !== true;
    }
  }

  document.addEventListener('DOMContentLoaded', init);
})();
