/**
 * ファイル名やディレクトリ名として使えない文字をアンダースコアに置換する
 * @param {string} name - サニタイズする文字列
 * @returns {string} - サニタイズ後の文字列
 */
function sanitize(name) {
    if (typeof name !== 'string') return '_';
    let sanitizedName = name.replace(/[\\/:*?"<>|]/g, '_');
    sanitizedName = sanitizedName.replace(/[. ]+$/, '');
    return sanitizedName || '_';
}

module.exports = { sanitize };