

import { createHash } from "node:crypto";

const SCHWIERIGKEIT = 3;
function sha256(text) {
  return createHash("sha256").update(text).digest("hex");
}

class Block {
  constructor(index, daten, vorherigerHash) {
    this.index = index;
    this.zeit = Date.now();
    this.daten = daten;
    this.vorherigerHash = vorherigerHash;
    this.nonce = 0;
    this.hash = this.berechneHash();
  }

  berechneHash() {
    return sha256(this.index + this.zeit + JSON.stringify(this.daten) + this.vorherigerHash + this.nonce);
  }

  
  mine() {
    const ziel = "0".repeat(SCHWIERIGKEIT);
    while (!this.hash.startsWith(ziel)) {
      this.nonce++;
      this.hash = this.berechneHash();
    }
    console.log(`Block ${this.index} gefunden nach ${this.nonce} Versuchen: ${this.hash}`);
  }
}

class Blockchain {
  constructor() {
    this.kette = [this.genesisBlock()];
  }

  genesisBlock() {
    const b = new Block(0, "Genesis", "0");
    b.mine();
    return b;
  }

  letzterBlock() {
    return this.kette[this.kette.length - 1];
  }

  blockHinzufuegen(daten) {
    const neu = new Block(this.kette.length, daten, this.letzterBlock().hash);
    neu.mine();
    this.kette.push(neu);
  }

  istGueltig() {
    for (let i = 1; i < this.kette.length; i++) {
      const aktuell = this.kette[i];
      const davor = this.kette[i - 1];

      if (aktuell.hash !== aktuell.berechneHash()) {
        console.log("Block " + i + " wurde verändert!");
        return false;
      }
      if (aktuell.vorherigerHash !== davor.hash) {
        console.log("Block " + i + " zeigt nicht auf den richtigen Vorgänger!");
        return false;
      }
    }
    return true;
  }
}


const gibb = new Blockchain();

gibb.blockHinzufuegen({ von: "Lea", an: "Tim", betrag: 5 });
gibb.blockHinzufuegen({ von: "Tim", an: "Noah", betrag: 2 });
gibb.blockHinzufuegen({ von: "Noah", an: "Lea", betrag: 1 });

console.log("\nKette gültig?", gibb.istGueltig());

// jetzt manipulieren wir mal einen Block
gibb.kette[1].daten.betrag = 500;
console.log("Nach Manipulation gültig?", gibb.istGueltig());

console.log("\n" + JSON.stringify(gibb.kette, null, 2));
