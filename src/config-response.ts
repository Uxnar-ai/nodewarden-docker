import { LIMITS } from './config/limits';

/**
 * 图标服务地址。
 *
 * 默认用本站：/icons/{host}/icon.png，由 Worker 自己去抓图。
 * 设置 ICON_SERVICE_URL 可让客户端直连外部图标服务，例如
 * https://icons.bitwarden.net —— 这样本站既不用抓图（省内存、省带宽），
 * 也不会把用户密码库里的域名写进自己的访问日志。
 */
function resolveIconService(origin: string, raw?: string) {
  const base = (raw || '').trim().replace(/\/+$/, '');
  if (!base) {
    return {
      origin,
      template: `${origin}/icons/{}/icon.png`,
      csp: `img-src 'self' data: ${origin}`,
    };
  }
  return {
    origin: base,
    template: `${base}/{}/icon.png`,
    csp: `img-src 'self' data: ${base}`,
  };
}

export function buildConfigResponse(origin: string, iconServiceUrl?: string) {
  const fillAssistBase = `${origin}/fill-assist/`;
  const iconService = resolveIconService(origin, iconServiceUrl);
  return {
    version: LIMITS.compatibility.bitwardenServerVersion,
    gitHash: 'nodewarden',
    server: null,
    environment: {
      cloudRegion: 'self-hosted',
      vault: origin,
      api: origin + '/api',
      identity: origin + '/identity',
      notifications: origin + '/notifications',
      icons: iconService.origin,
      sso: '',
      fillAssistRules: fillAssistBase,
    },
    push: {
      pushTechnology: 0,
      vapidPublicKey: null,
    },
    communication: null,
    settings: {
      disableUserRegistration: false,
      suppressOnboardingInterstitials: false,
    },
    _icon_service_url: iconService.template,
    _icon_service_csp: iconService.csp,
    featureStates: {
      'cipher-key-encryption': LIMITS.compatibility.cipherKeyEncryptionFeatureEnabled,
      'desktop-ui-settings-dialog': true,
      'duo-redirect': true,
      'email-verification': true,
      'fill-assist-targeting-rules': true,
      'pm-19051-send-email-verification': false,
      'pm-19148-innovation-archive': true,
      'pm-4516-devices-add-last-activity-date': true,
      'pm-30529-webauthn-related-origins': true,
      'unauth-ui-refresh': true,
      'web-push': false,
    },
    object: 'config',
  };
}
