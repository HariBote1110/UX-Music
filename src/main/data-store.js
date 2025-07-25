const path = require('path');
const fs = require('fs');
const { app } = require('electron'); // ★★★ appモジュールを直接読み込む ★★★

class DataStore {
    constructor(fileName) {
        // ★★★ app.getPathをコンストラクタ内で使用するように変更 ★★★
        const userDataPath = app.getPath('userData');
        this.path = path.join(userDataPath, fileName);
        this.fileName = fileName;
        console.log(`[DataStore] Path for ${this.fileName}: ${this.path}`); // デバッグ用にパスを出力
    }

    load() {
        try {
            if (fs.existsSync(this.path)) {
                const fileContent = fs.readFileSync(this.path, 'utf-8');
                if (fileContent.trim() === '') {
                    return this.fileName === 'library.json' ? [] : {};
                }
                return JSON.parse(fileContent);
            }
        } catch (error) {
            console.error(`Failed to load data from ${this.path}:`, error);
        }
        return this.fileName === 'library.json' ? [] : {};
    }

    save(data) {
        try {
            fs.writeFileSync(this.path, JSON.stringify(data, null, 2));
        } catch (error) {
            console.error(`Failed to save data to ${this.path}:`, error);
        }
    }
}

module.exports = DataStore;