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
                const fileContent = fs.readFileSync(this.path, 'utf-8');
                if (fileContent.trim() === '') {
                    // ★★★ 修正箇所 ★★★
                    // 'library.json' と 'playcounts.json' はデフォルトが異なる可能性があるため、
                    // 空の場合は常に {} を返し、呼び出し元で処理を分けるようにする
                    return {};
                }
                return JSON.parse(fileContent);
            }
        } catch (error) {
            console.error(`Failed to load data from ${this.path}:`, error);
        }
        // ★★★ 修正箇所 ★★★
        // ファイルが存在しない場合のデフォルト値も {} に統一する
        return {};
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