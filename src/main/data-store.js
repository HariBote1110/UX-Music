const path = require('path');
const fs = require('fs');

class DataStore {
    constructor(fileName) {
        const userDataPath = require('electron').app.getPath('userData');
        this.path = path.join(userDataPath, fileName);
        this.fileName = fileName;
    }

    load() {
        try {
            if (fs.existsSync(this.path)) {
                // ★★★ ここからが修正箇所です ★★★
                const fileContent = fs.readFileSync(this.path, 'utf-8');
                // ファイルが空、または空白文字しかない場合は、デフォルト値を返す
                if (fileContent.trim() === '') {
                    return this.fileName === 'library.json' ? [] : {};
                }
                return JSON.parse(fileContent);
                // ★★★ ここまでが修正箇所です ★★★
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