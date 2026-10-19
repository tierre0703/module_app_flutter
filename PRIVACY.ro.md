# Politica de Confidențialitate — Soleux Device Manager

**Ultima actualizare:** 18 octombrie 2026

---

## 1. Introducere

Soleux Device Manager ("Aplicația") este unealtă de configurare și monitorizare locală pentru modulele hardware Soleux (Relay, PDU, AC Dimmer, DC Dimmer și module de temperatură). Această Politică de Confidențialitate explică ce date colectează Aplicația, cum sunt utilizate și drepturile dumneavoastră referitoare la aceste date.

Prin utilizarea Aplicației, vă exprimați acordul cu practicile descrise în presente politică.

---

## 2. Operatorul de Date

Aplicația este dezvoltată și publicată de **Soleux**.  
Contact: [support@soleux.com](mailto:support@soleux.com)

---

## 3. Datele Colectate

Aplicația este concepută să funcționeze **în principal în rețea locală**. Nicio dată nu este trimisă către servere externe decât dacă activați în mod explicit funcțiile cloud. Mai jos este prezentată una defalcare completă a datelor stocate și procesate:

### 3.1 Date Stocare Local (pe dispozitivul dumneavoastră)

Toate datele de configurare sunt stocare locale în zona sigură de stocare a aplicației (bază de date SQLite și depozit de preferință). Acestea includ:

| Categoria | Punctele de Date |
|-----------|------------------|
| **Configurare Modul** | ID modul, nume, tip, adresă IP, port TCP, versione firmware, număr serial, adresă MAC, tip conexiune (local/remote/cloud), starea online/offline, timestamp ultima vedere |
| **Setări Canale/Ieșire** | Nume canale, icoane, starea ON/OFF, niveluri luminozitate, mărime pas, nume intrare fizică, moduri intrare |
| **Praguri Temperatură** | Praguri min/max temperatură per modul, informații sistem (CPU, memorie, uptime, rețea) |
| **Camere & Zone** | ID-uri și nume camere pentru organizare module |
| **Scenarii** | ID-uri scenarii, nume, icoane, tipuri, atribuire camere, flag afișare-acasă, culori fundal, acțiuni per canal |
| **Automatizări** | ID-uri automatizări, nume, tipuri trigger (timp/stare-dispozitiv), programări, indexuri module/canale/intrări monitorizate, acțiuni |
| **Preferințe Aplicație** | Temă (light/dark/system), limbă, paletă culoare, setări notificări, prag temperatură implicit, prag ore pornire, mod transport comandă, nume locație, culori personalizate |
| **Stare Sesiune** | Flag boolean autentificat (niciodată credentială stocare) |
| **Jurnal Evenimente** | Istoric 30 de zile: acțiuni modul, executare scenarii, trigger automatizări — timestamp, titluri, subtitlu |
| **Istoric Notificări** | Notificări eveniment offline/restored/firmware (retenție 30 de zile) |

### 3.2 Date Transmise în Rețeau Locală

Pentru descoperirea și controlul modulelor hardware Soleux, Aplicația trimite și primește date în rețeau dumneavoastră locală:

- **Descoperire UDP broadcast** — Aplicația trimite pachet de descoperire în rețeau locală pentru găsirea modulelor Soleux
- **Comande TCP** — comende ON/OFF, luminozitate și configurare trimise direct modulelor via TCP (port 5008, protocol JSON)
- **Răspunsuri stare modul** — modulele răspund cu starea lor curentă, lecturare și informații diagnostice

Aceasă comunicare rămâne entral în rețeau dumneavoastră locală și nu este transmisă prin internet.

### 3.3 Date Pe Care Alegeți să Exportați

Aplicația include o funcție de **backup/restore** care permite exportarea tuturor configurațiilor locale într-un fișier JSON. Acest fișier se salvează în sistemul dumneavoastră de fișiere. Dumneavoastră controlați unde este stocat și dacă partajați cu cineva. Nicio dată nu este încărcată automat către server.

### 3.4 Funcții Cloud (Viitoare / Opt-In)

Arhitectura Aplicației include schelet pentru seguentele funcții cloud viitore. **Acestea NU sunt active** decât dacă le configurați și activați explicit:

- **Acces Remote MQTT** — Dacă activat, comende module și date stare ar transmite via broker MQTT configurat de dumneavoastră
- **Sincronizare Cloud Firebase** — Dacă activat într-un release viitor, credentială și backup-uri configurație sincronizate via Firebase
- **Notificări Push** — Dacă activat într-un release viitor, Firebase Cloud Messaging (FCM) ar trimite notificări

**În prezent (versione 1.0.25), niciuna dintre funcție cloud de mai sus este operațională.** Toate funcțiile aplicației sunt limitate la rețeau locală.

---

## 4. Cum Utilizăm Datele

| Scop | Date Utilizate |
|------|----------------|
| **Descoperire & control module** | IP modul, port, stare, date canale |
| **Persiste configurație** | Toate setări modul, cameră, scenarii, automatizări |
| **Executare scenarii & automatizări** | Definiții scenarii/automatizări, condiții trigger |
| **Istoric evenimente** | Jurnal eveniment pentru afişare activitate recentă |
| **Livrare notificări** | Istoric notificări, praguri temperatură |
| **Personalizare aplicație** | Temă, limbă, preferințe UI |
| **Backup & restore** | Toate configurați locale (export/import inițiat de utilizator) |

Nu utilizăm datele dumneavoastră pentru publicitate, profilare, analytics sau decizie automatizată.

---

## 5. Analytics & Raportare Crash

Aplicația **nu conține** unelte analytics, telemetrie sau raportare crash. Niciodată date de utilizare sunt colectate sau transmise.

---

## 6. Retenția Datelor

| Tip Date | Perioada Retenție |
|----------|-------------------|
| Configurare module | Până la șterge sau factory reset |
| Camere, scenarii, automatizări | Până la șterge de către utilizator |
| Jurnal evenimente | 30 de zile rolling |
| Istoric notificări | 30 de zile rolling |
| Fișier backup | Câtă timp păstrați dumneavoastră |

---

## 7. Securitatea Datelor

### 7.1 Stocare Locală

- Toate datele stocare în zona sigură a aplicației (standard pentru aplicațiile Flutter)
- Nicio encriptare aplicată stocari locale (datele nu párăs dispozitive dumneavoastră)
- Niciodată parole, API keys sau tokeni autentificare serviciu cloud stocare

### 7.2 Comunicație Rețeau Locală

- Comunicație cu modulele Soleux via rețeau dumneavoastră **locală TCP/UDP**
- Nicio encriptare aplicată comande rețeau locală (standard pentru protocole industriale locale)
- Datele nu traverse internetul public

---

## 8. Drepturile Dumneavoastră

În funcție de jurisdictia dumneavoastră (GDPR în Uniun Europeană, CCPA în California):

| Dreptul | Cum Să Exerciți |
|---------|-----------------|
| **Access** | Toate datele dumneavoastră sunt vizibile în Aplicație. Exportați backup via Setări → Backup |
| **Rectificare** | Editați modul, cameră, scenarii sau automatizări direct în Aplicație |
| **Şterge** | Ştergeți itemi individuali via interface Aplicație. Pentru șterge tot, dezinstalați Aplicația |
| **Portabilitate** | Utilizați backup feature pentru exportați toate datele |
| **Retrage Acord** | Dezinstalați Aplicația oricând |
| **Plânge** | Contactați autoritatea dumneavoastră locală de protecție a datelor |

---

## 9. Serviciile Terțe & Partajare Date

Aplicația **nu partajează** datele dumneavoastră cu nicio terță parte. Nu vindem, închiriem sau facem troc cu informați dumneavoastră.

Niciodată servicii analytics, advertising sau social media sunt integrate.

---

## 10. Contact

**Email:** [support@soleux.com](mailto:support@soleux.com)

---

*© 2026 Soleux. Toate drepturile rezervate.*