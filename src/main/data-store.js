const path = require('path');
const fs = require('fs');

class DataStore {
    constructor(fileName) {
        const userDataPath = require('electron').app.getPath('userData');
        this.path = path.join(userDataPath, fileName);
        // ★★★ 追加: ファイル名をインスタンスに保存 ★★★
        this.fileName = fileName;
    }

    load() {
        try {
            if (fs.existsSync(this.path)) {
                return JSON.parse(fs.readFileSync(this.path));
            }
        } catch (error) {
            console.error(`Failed to load data from ${this.path}:`, error);
        }
        // ★★★ 修正: library.jsonの場合は空配列、それ以外は空オブジェクトを返す ★★★
        return this.fileName === 'library.json' ? [] : {};
    }

    // (save関数は変更なし)
    save(data) {
        try {
            fs.writeFileSync(this.path, JSON.stringify(data, null, 2));
        } catch (error) {
            console.error(`Failed to save data to ${this.path}:`, error);
        }
    }
}
// 他のファイルで使えるようにエクスポート
module.exports = DataStore;