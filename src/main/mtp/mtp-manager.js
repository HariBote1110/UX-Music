let mtpDevice = null;

module.exports = {
  /**
   * MTPデバイスインスタンスを設定
   * @param {Kalam | null} device
   */
  setDevice: (device) => {
    mtpDevice = device;
  },
  
  /**
   * MTPデバイスインスタンスを取得
   * @returns {Kalam | null}
   */
  getDevice: () => {
    return mtpDevice;
  },
};