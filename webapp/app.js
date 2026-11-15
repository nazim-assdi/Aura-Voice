(() => {
  'use strict';

  const API_BASE = 'https://aura-voice-api.onrender.com';
  const HISTORY_KEY = 'aura-voice-studio-history-v1';
  const MAX_HISTORY = 40;
  const $ = (id) => document.getElementById(id);
  const state = {
    health: null, voices: [], voiceCache: new Map(),
    currentAudioUrl: null, currentBlob: null, currentFormat: 'wav',
    generating: false, toastTimer: null
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
    node.textContent = message;
    node.classList.toggle('error', Boolean(isError));
    node.classList.add('show');
    window.clearTimeout(state.toastTimer);
    state.toastTimer = window.setTimeout(() => node.classList.remove('show'), 3200);
  }

  function setNotice(message, kind) {
    const node = $('noticeBar');
    node.textContent = message || '';
    node.className = 'notice-bar';
    if (kind) node.classList.add(kind);
  }

  function formatLanguageLabel(code) {
    const labels = { en: 'English', bn: 'বাংলা', ar: 'العربية', hi: 'हिन्दी' };
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
    const value = $('scriptText').value;
    $('charCount').textContent = value.length.toLocaleString();
    $('generateButton').disabled = state.generating || value.trim().length === 0 || value.length > 5000;
  }

  async function fetchJson(url, options) {
    const opts = options || {};
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), opts.timeout || 25000);
    try {
      const response = await fetch(url, {
        method: opts.method || 'GET',
        headers: Object.assign({ Accept: 'application/json' }, opts.headers || {}),
        body: opts.body,
        signal: controller.signal
      });
      const type = response.headers.get('content-type') || '';
      const body = type.indexOf('application/json') >= 0 ? await response.json() : await response.text();
      if (!response.ok) {
        let message = 'Request failed (' + response.status + ')';
        if (body && typeof body === 'object') {
          const detail = body.detail;
          if (typeof detail === 'string') message = detail;
          else if (detail && typeof detail === 'object') message = detail.message || detail.code || message;
        } else if (typeof body === 'string' && body) {
          message = body;
        }
        throw new Error(message);
      }
      return body;
    } finally {
      window.clearTimeout(timer);
    }
  }

  function renderHealth(data) {
    state.health = data;
    const online = data.online === true;
    const configured = data.configured === true;
    $('engineDot').className = 'engine-dot ' + (online ? (configured ? 'online' : '') : 'offline');
    $('topStatusDot').className = 'status-pulse ' + (online ? 'online' : 'offline');
    $('sidebarEngine').textContent = !online ? 'API unavailable' : configured ? 'Cartesia configured' : 'API online';
    $('sidebarEngineNote').textContent = !online
      ? 'Could not reach the backend'
      : configured ? 'Speech provider key is present' : 'Cartesia API key is required';
    $('topStatusText').textContent = !online ? 'API offline' : configured ? 'Engine configured' : 'API online';
    $('settingsStatusDot').className = 'status-pulse ' + (online ? 'online' : 'offline');
    $('settingsApiStatus').textContent = online ? 'Online' : 'Unavailable';
    $('settingsApiStatus').style.color = online ? 'var(--mint)' : 'var(--danger)';
    $('settingsProvider').textContent = data.provider || 'Not configured';
    $('settingsVersion').textContent = data.version || '—';
  }

  async function checkHealth() {
    try {
      const result = await fetchJson(API_BASE + '/health', { timeout: 12000 });
      renderHealth({
        online: result.ok === true,
        configured: result.speech_ready === true,
        provider: result.speech_provider || 'none',
        version: result.version || ''
      });
    } catch (_) {
      renderHealth({ online: false, configured: false, provider: 'none', version: '' });
    }
    return state.health;
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
    voices.forEach((voice) => {
      const suffix = voice.tagline ? ' — ' + voice.tagline : '';
      select.append(new Option((voice.name || 'Unnamed voice') + suffix, voice.id));
    });
    select.disabled = false;
    select.value = voices[0].id;
  }

  async function loadVoices(language, force) {
    const select = $('voiceSelect');
    const note = $('voiceNote');
    select.replaceChildren(new Option('Loading voices…', ''));
    select.disabled = true;
    note.textContent = 'Loading available voices for ' + formatLanguageLabel(language) + '…';

    if (!force && state.voiceCache.has(language)) {
      state.voices = state.voiceCache.get(language);
      renderVoiceOptions(state.voices);
      note.textContent = state.voices.length + ' voices available.';
      return state.voices;
    }

    try {
      const data = await fetchJson(API_BASE + '/api/v1/speech/voices?language=' +
        encodeURIComponent(language) + '&limit=100');
      const voices = Array.isArray(data.voices) ? data.voices : [];
      state.voices = voices;
      state.voiceCache.set(language, voices);
      renderVoiceOptions(voices);
      note.textContent = voices.length
        ? voices.length + ' voices available for ' + formatLanguageLabel(language) + '.'
        : 'No voices were returned for this language.';
      return voices;
    } catch (error) {
      state.voices = [];
      select.replaceChildren(new Option('Voice catalogue unavailable', ''));
      select.disabled = true;
      note.textContent = error.message || 'Could not load the voice catalogue.';
      setNotice(error.message || 'Check the Cartesia API key on the backend.', 'error');
      return [];
    }
  }

  function renderVoiceLibrary() {
    const grid = $('voiceGrid');
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
        : 'No voices available. Check your Cartesia key and refresh.';
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
      const tag = document.createElement('span');
      tag.className = 'voice-tag';
      tag.textContent = voice.gender || voice.language || 'Cartesia';
      top.append(avatar, tag);
      const title = document.createElement('h3');
      title.textContent = voice.name || 'Unnamed voice';
      const desc = document.createElement('p');
      desc.textContent = voice.tagline || (voice.language || 'Multilingual') + ' voice';
      const use = document.createElement('button');
      use.className = 'secondary-button';
      use.type = 'button';
      use.textContent = 'Use this voice';
      use.addEventListener('click', () => {
        $('languageSelect').value = $('voiceLanguageFilter').value;
        $('scriptLanguageLabel').textContent = formatLanguageLabel($('languageSelect').value);
        loadVoices($('languageSelect').value).then(() => {
          $('voiceSelect').value = voice.id;
          navigate('studio');
          showToast((voice.name || 'Voice') + ' selected');
        });
      });
      card.append(top, title, desc, use);
      grid.append(card);
    });
  }

  async function loadVoiceLibrary(language, force) {
    if (force) state.voiceCache.delete(language);
    if (!state.voiceCache.has(language)) await loadVoices(language, force);
    else state.voices = state.voiceCache.get(language);
    renderVoiceLibrary();
  }

  function readHistory() {
    try {
      const items = JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]');
      return Array.isArray(items) ? items : [];
    } catch (_) {
      return [];
    }
  }

  function saveHistory(entry) {
    try {
      const items = readHistory();
      items.unshift(entry);
      localStorage.setItem(HISTORY_KEY, JSON.stringify(items.slice(0, MAX_HISTORY)));
    } catch (_) {
      showToast('Browser storage is full. Your audio is still available to download.', true);
    }
    renderHistory();
  }

  function renderHistory() {
    const list = $('historyList');
    list.replaceChildren();
    const items = readHistory();
    if (!items.length) {
      const empty = document.createElement('div');
      empty.className = 'empty-history';
      empty.textContent = 'Your recent projects will appear here after your first generation.';
      list.append(empty);
      return;
    }
    items.forEach((item) => {
      const row = document.createElement('div');
      row.className = 'history-item';
      const info = document.createElement('div');
      info.className = 'history-main';
      const title = document.createElement('strong');
      title.textContent = item.name || 'Untitled project';
      const details = document.createElement('small');
      details.textContent = formatLanguageLabel(item.language) + ' · ' +
        String(item.format || 'wav').toUpperCase() + ' · ' + new Date(item.createdAt).toLocaleString();
      info.append(title, details);
      const open = document.createElement('button');
      open.className = 'history-open';
      open.type = 'button';
      open.textContent = 'Open script';
      open.addEventListener('click', () => {
        $('projectName').value = item.name || 'Untitled voice project';
        $('scriptText').value = item.text || '';
        $('languageSelect').value = item.language || 'en';
        $('speedRange').value = item.speed || 1;
        $('speedValue').textContent = Number(item.speed || 1).toFixed(1) + '×';
        $('volumeRange').value = item.volume || 1;
        $('volumeValue').textContent = Number(item.volume || 1).toFixed(1) + '×';
        $('emotionSelect').value = item.emotion || '';
        const radio = document.querySelector('input[name="format"][value="' + (item.format || 'wav') + '"]');
        if (radio) radio.checked = true;
        updateFormatSelection();
        updateCharacterCount();
        $('languageSelect').dispatchEvent(new Event('change'));
        navigate('studio');
        showToast('Project script loaded');
      });
      row.append(info, open);
      list.append(row);
    });
  }

  function navigate(page) {
    document.querySelectorAll('.page').forEach((node) => {
      node.classList.toggle('active', node.id === 'page-' + page);
    });
    document.querySelectorAll('.nav-item').forEach((node) => {
      node.classList.toggle('active', node.dataset.page === page);
    });
    const names = { studio: 'Studio', voices: 'Voice library', history: 'Projects', settings: 'Settings' };
    $('breadcrumbCurrent').textContent = names[page] || 'Studio';
    $('sidebar').classList.remove('open');
    if (page === 'voices') {
      $('voiceLanguageFilter').value = $('languageSelect').value;
      loadVoiceLibrary($('voiceLanguageFilter').value, false);
    }
    if (page === 'history') renderHistory();
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
      const response = await fetch(API_BASE + '/api/v1/speech/generate', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: format === 'mp3' ? 'audio/mpeg' : 'audio/wav'
        },
        body: JSON.stringify(payload)
      });
      if (!response.ok) {
        let message = 'Speech generation failed (' + response.status + ')';
        try {
          const err = await response.json();
          if (typeof err.detail === 'string') message = err.detail;
          else if (err.detail && typeof err.detail === 'object') message = err.detail.message || err.detail.code || message;
        } catch (_) {}
        throw new Error(message);
      }
      const blob = await response.blob();
      if (!blob.size) throw new Error('The speech provider returned an empty audio file.');
      if (state.currentAudioUrl) URL.revokeObjectURL(state.currentAudioUrl);
      state.currentBlob = blob;
      state.currentAudioUrl = URL.createObjectURL(blob);
      state.currentFormat = format;
      $('audioPlayer').src = state.currentAudioUrl;
      $('outputName').textContent = $('projectName').value.trim() || 'Untitled voice project';
      const chosen = state.voices.find((voice) => voice.id === payload.voice_profile_id);
      $('outputMeta').textContent = format.toUpperCase() + ' · ' +
        (chosen ? chosen.name : 'Cartesia Sonic') + ' · ' + formatLanguageLabel(payload.language);
      $('outputFileInfo').textContent = (blob.size / 1024).toFixed(0) + ' KB · Ready to listen and download';
      $('outputEmpty').classList.add('hidden');
      $('outputContent').classList.remove('hidden');
      setNotice('Your audio is ready. Listen to the preview or download the file.', 'success');
      saveHistory({
        name: $('projectName').value.trim() || 'Untitled voice project',
        text: text,
        language: payload.language,
        format: format,
        voiceId: payload.voice_profile_id,
        speed: payload.speed,
        volume: payload.volume,
        emotion: payload.emotion,
        createdAt: new Date().toISOString()
      });
      $('audioPlayer').play().catch(() => {});
      showToast('Voice generated successfully');
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

  function downloadAudio() {
    if (!state.currentBlob) {
      showToast('Generate audio before downloading.', true);
      return;
    }
    const raw = $('projectName').value.trim() || 'aura-voice';
    const safe = raw.normalize('NFKD').replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').toLowerCase() || 'aura-voice';
    const url = URL.createObjectURL(state.currentBlob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = safe + '.' + state.currentFormat;
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1500);
    showToast('Download started');
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

  function bindEvents() {
    document.querySelectorAll('.nav-item').forEach((button) => {
      button.addEventListener('click', () => navigate(button.dataset.page));
    });
    $('mobileMenu').addEventListener('click', () => $('sidebar').classList.toggle('open'));
    $('generateButton').addEventListener('click', generateSpeech);
    $('downloadButton').addEventListener('click', downloadAudio);
    $('scriptText').addEventListener('input', updateCharacterCount);
    $('speedRange').addEventListener('input', () => {
      $('speedValue').textContent = Number($('speedRange').value).toFixed(1) + '×';
    });
    $('volumeRange').addEventListener('input', () => {
      $('volumeValue').textContent = Number($('volumeRange').value).toFixed(1) + '×';
    });
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
    $('retryHealth').addEventListener('click', checkHealth);
    $('settingsReconnect').addEventListener('click', async () => {
      await checkHealth();
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
      } catch (_) {
        showToast('Clipboard access was blocked by your browser.', true);
      }
    });
    $('openApiDocs').addEventListener('click', () => window.open(API_BASE + '/docs', '_blank', 'noopener'));
    $('clearHistory').addEventListener('click', () => {
      localStorage.removeItem(HISTORY_KEY);
      renderHistory();
      showToast('Local project history cleared');
    });
    document.querySelectorAll('.template-chip').forEach((button) => {
      button.addEventListener('click', () => applyTemplate(button.dataset.template));
    });
  }

  async function init() {
    $('apiEndpoint').textContent = API_BASE;
    bindEvents();
    updateCharacterCount();
    updateFormatSelection();
    renderHistory();
    await checkHealth();
    await loadVoices($('languageSelect').value, false);
  }

  document.addEventListener('DOMContentLoaded', init);
})();
