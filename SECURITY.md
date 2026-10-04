# Security

Dokumen ini menjelaskan model keamanan Kaji Finance berdasarkan implementasi yang terdapat di repository.

> **Catatan penting:** ini adalah dokumentasi keamanan berdasarkan pemeriksaan kode repository, bukan sertifikasi keamanan atau audit penetrasi independen. Tidak ada aplikasi yang dapat dijamin 100% aman.

## Gambaran keamanan

Kaji Finance dirancang sebagai aplikasi **offline-first**. Data keuangan utama disimpan di perangkat dan aplikasi tidak memerlukan backend cloud untuk fungsi keuangan sehari-hari.

Perlindungan dibangun dalam beberapa lapisan:

1. Database lokal terenkripsi.
2. Perlindungan akses menggunakan PIN dan biometrik.
3. PIN tidak disimpan sebagai teks biasa.
4. Percobaan PIN dibatasi dengan mekanisme lockout.
5. Data keamanan dipisahkan berdasarkan profil.
6. Backup tidak membawa PIN perangkat.
7. Data impor diperiksa sebelum ditulis ke database.
8. Aktivitas penting dicatat melalui audit log.
9. Log aplikasi berusaha menghapus informasi yang berpotensi menjadi rahasia.
10. Aplikasi dapat memblokir screenshot dan pratinjau recent apps.

## Perlindungan database

Data finansial utama disimpan menggunakan SQLite yang dilindungi SQLCipher.

Artinya, isi database tidak dimaksudkan untuk dapat dibaca langsung sebagai database SQLite biasa apabila seseorang memperoleh berkas database aplikasi.

Kunci database dikelola melalui lapisan penyimpanan aman aplikasi dan penggunaan database juga dipisahkan berdasarkan profil.

## PIN

PIN tidak disimpan dalam bentuk teks biasa.

Implementasi saat ini menggunakan:
- Salt acak.
- PBKDF2-HMAC-SHA256.
- 10.000 iterasi.
- Hasil hash disimpan melalui secure storage perangkat.
- Perbandingan hasil verifikasi dilakukan dengan pendekatan constant-time.

Ada mekanisme migrasi untuk format PIN lama agar data pengguna lama dapat diperbarui ke format yang lebih baru ketika berhasil diverifikasi.

### Lockout

Percobaan PIN yang gagal dicatat secara persisten dan digunakan untuk menerapkan jeda setelah terlalu banyak kegagalan.

Batas yang terlihat pada implementasi saat ini adalah 5 percobaan sebelum lockout. Durasi lockout meningkat secara bertahap hingga beberapa menit.

Status lockout disimpan melalui secure storage dan dipisahkan berdasarkan profil. Tujuannya agar restart aplikasi tidak memberikan kesempatan baru untuk terus menebak PIN.

## Biometrik

Aplikasi dapat menggunakan autentikasi biometrik yang disediakan perangkat.

Biometrik tidak menggantikan mekanisme penyimpanan PIN. Aplikasi tetap menggunakan kontrol akses perangkat dan penyimpanan aman untuk menjaga state keamanan.

## Penguncian otomatis

Aplikasi dapat mengunci ketika masuk ke latar belakang.

Pengguna dapat mengatur timeout. Nilai yang tersedia pada implementasi mencakup:
- Segera.
- 1 menit.
- 5 menit.

Aplikasi memiliki perlindungan tambahan agar aktivitas seperti file picker, share sheet, dan proses autentikasi tidak salah dianggap sebagai pengguna meninggalkan aplikasi.

## Perlindungan screenshot

Terdapat pilihan untuk mengaktifkan perlindungan screenshot.

Jika diaktifkan, aplikasi menggunakan mekanisme native Android untuk mencegah screenshot dan mengurangi informasi yang terlihat pada pratinjau recent apps.

Fitur ini tidak aktif secara default sehingga pengguna dapat memilih tingkat perlindungan yang sesuai kebutuhannya.

## Isolasi profil

Setiap profil memiliki ruang penyimpanan yang berbeda.

ID profil dibatasi dengan aturan karakter yang ketat. Hal ini penting karena ID profil digunakan sebagai bagian dari nama database dan kunci penyimpanan.

ID yang tidak memenuhi aturan ditolak sehingga aplikasi tidak sembarangan membentuk nama file dari input pengguna.

## Backup

Backup penuh mencakup data keuangan dan pengaturan tertentu yang memang diperlukan untuk pemulihan.

PIN dan status PIN perangkat **tidak** ikut dimasukkan ke backup.

Backup penuh divalidasi sebelum restore. Aplikasi memeriksa format, struktur, model data, dan nilai nominal agar data yang rusak tidak langsung masuk ke database.

Restore juga menggunakan jurnal untuk membantu mendeteksi proses pemulihan yang terhenti karena aplikasi crash atau perangkat dimatikan.

### Hal yang perlu dipahami pengguna

File backup yang sudah diekspor dapat berupa file yang dapat dipindahkan dan dibagikan. Keamanan file tersebut setelah keluar dari aplikasi bergantung pada tempat file disimpan.

Karena itu:
- Jangan mengirim backup kepada orang yang tidak dipercaya.
- Hindari menyimpan backup tanpa perlindungan pada perangkat bersama.
- Jika menggunakan cloud storage, aktifkan perlindungan akun cloud tersebut.
- Setelah restore pada perangkat baru, aktifkan kembali PIN atau biometrik.

## Impor data

Impor transaksi tidak langsung memasukkan isi file ke database.

Alurnya:
1. File dibaca ke memori.
2. Struktur dan nilai transaksi diperiksa.
3. Baris yang rusak dilewati.
4. Data yang lolos baru ditulis ke database terenkripsi.
5. Perubahan terkait dompet dan anggaran diterapkan melalui mekanisme transaksi aplikasi.

Ukuran file impor juga dibatasi untuk mengurangi risiko penggunaan memori secara berlebihan.

## Audit log

Aplikasi memiliki audit service untuk merekam aktivitas penting seperti perubahan kredensial, perubahan pengaturan keamanan, backup, restore, dan operasi finansial tertentu.

Audit log tidak dirancang untuk menyimpan PIN, password, kunci, atau isi rahasia.

## Logging

Logging aplikasi menerapkan penyaringan terhadap nama field yang umum digunakan untuk rahasia, misalnya PIN, password, token, salt, hash, kunci database, dan nonce.

Nilai log yang panjang juga dipotong.

Meski demikian, logging tidak boleh dianggap sebagai tempat aman untuk menyimpan data sensitif. Pengembangan fitur baru tetap harus menghindari memasukkan data finansial atau kredensial ke pesan log.

## CI dan signing Android

Workflow CI menyimpan material signing Android melalui GitHub Actions Secrets, bukan di source code.

Workflow terbaru juga membatasi proses yang menggunakan keystore agar tidak dijalankan pada pull request dari repository fork yang tidak dipercaya, memeriksa keberadaan secret, memeriksa keystore sebelum build, dan membersihkan file keystore sementara setelah digunakan.

Build release menggunakan obfuscation dan memisahkan informasi debug.

### Catatan audit

Konfigurasi build Android memiliki fallback ke debug signing apabila file keystore release tidak tersedia. Ini berguna agar project tetap dapat dibangun pada lingkungan tertentu, tetapi **untuk distribusi produksi, release signing harus dikonfigurasi dengan keystore produksi yang benar**.

Jangan menganggap APK yang berhasil dibuat otomatis merupakan artefak produksi yang aman untuk didistribusikan.

## Batasan keamanan

Beberapa risiko berada di luar kendali aplikasi:

- Perangkat yang sudah di-root atau dikompromikan dapat melemahkan perlindungan penyimpanan lokal.
- Malware yang memiliki akses tinggi pada perangkat dapat membaca atau memanipulasi data.
- Orang yang memperoleh PIN pengguna dapat membuka aplikasi.
- File backup yang disalin keluar dari aplikasi dapat dibaca jika tidak dilindungi oleh media penyimpanan.
- Screenshot dari perangkat lain tentu tidak dapat dicegah oleh aplikasi.
- Keamanan sistem operasi, Android, firmware, dan perangkat keras tetap menjadi bagian dari model ancaman.

## Pelaporan kerentanan

Jika Anda menemukan kerentanan keamanan, jangan publikasikan detail eksploit secara langsung di issue publik.

Sebaiknya hubungi pemelihara repository melalui kanal privat yang tersedia untuk repository ini dan sertakan:
- Deskripsi masalah.
- Versi aplikasi yang terdampak.
- Langkah reproduksi.
- Dampak yang mungkin terjadi.
- Bukti pendukung yang tidak mengandung data pengguna.

Jangan mengirim PIN, password, token, backup pribadi, atau data finansial nyata ketika melaporkan masalah.

## Rekomendasi untuk pengguna

Untuk perlindungan terbaik:

- Aktifkan PIN dan/atau biometrik.
- Gunakan PIN yang tidak mudah ditebak.
- Aktifkan penguncian otomatis.
- Aktifkan perlindungan screenshot jika perangkat sering digunakan di tempat umum.
- Buat backup secara berkala.
- Simpan backup di tempat yang terlindungi.
- Jangan membagikan backup secara sembarangan.
- Selalu gunakan versi aplikasi terbaru yang tersedia.
