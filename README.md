# Kaji Finance

Kaji Finance adalah aplikasi keuangan pribadi berbasis Android yang membantu mencatat, mengatur, dan memahami kondisi keuangan sehari-hari.

Aplikasi ini dibuat dengan pendekatan **offline-first**: data utama disimpan di perangkat, bukan bergantung pada layanan cloud untuk penggunaan sehari-hari.

> **Status:** versi aplikasi yang tertera di project saat ini adalah **1.3.0+1**.

## Apa yang bisa dilakukan?

### Pencatatan keuangan
- Mencatat pemasukan dan pengeluaran.
- Mencatat transfer antar dompet.
- Mencatat penyesuaian saldo.
- Menambahkan kategori, tag, catatan, dan informasi transaksi.
- Mengubah atau menghapus transaksi.
- Mencari dan memfilter transaksi berdasarkan kategori, bulan, dan rentang tanggal.
- Menampilkan transaksi berdasarkan hari sehingga riwayat lebih mudah dibaca.

### Banyak dompet
Anda dapat menggunakan lebih dari satu dompet atau akun, misalnya uang tunai, rekening bank, atau dompet digital.

Transfer antar dompet dapat dicatat sebagai transaksi sehingga perpindahan uang tidak dianggap sebagai pemasukan atau pengeluaran baru.

### Anggaran
Anda dapat membuat anggaran berdasarkan kategori dan memantau penggunaannya.

Aplikasi juga menyediakan peringatan ketika penggunaan anggaran melewati tingkat tertentu, termasuk peringatan 50%, 80%, dan 100% pada logika aplikasi.

### Target tabungan
Anda dapat membuat target tabungan, menentukan jumlah yang ingin dicapai, menambahkan progres tabungan, dan memberikan batas waktu.

Progres target dapat dilihat sebagai persentase sehingga lebih mudah mengetahui apakah target sudah mendekati selesai.

### Hutang dan piutang
Aplikasi memiliki pencatatan hutang sehingga kewajiban atau uang yang perlu diterima dapat dipantau secara terpisah dari transaksi harian.

### Tagihan rutin
Tagihan yang berulang dapat dicatat beserta jadwalnya. Fitur ini membantu mengingat kewajiban yang muncul secara berkala.

### Analisis keuangan
Halaman analisis membantu melihat pola pemasukan dan pengeluaran berdasarkan data yang sudah dicatat.

### Impor dan ekspor
Data dapat dipindahkan menggunakan berkas:
- Backup penuh aplikasi.
- Backup transaksi.
- CSV transaksi.

Impor transaksi memiliki tahap pemeriksaan terlebih dahulu. Data yang tidak valid dapat dilewati agar tidak langsung masuk ke penyimpanan.

### Notifikasi
Aplikasi mendukung:
- Peringatan anggaran.
- Pengingat target tabungan.
- Ringkasan keuangan terjadwal.
- Notifikasi yang dapat diarahkan ke bagian tertentu dari aplikasi.

Permintaan izin notifikasi tidak dipaksa ketika aplikasi baru dibuka. Izin diminta ketika fitur notifikasi memang diperlukan.

### Keamanan aplikasi
Kaji Finance menyediakan beberapa lapisan perlindungan:
- PIN untuk mengunci aplikasi.
- Biometrik perangkat jika tersedia.
- Penguncian setelah aplikasi masuk ke latar belakang.
- Perlindungan terhadap percobaan PIN berulang.
- Database lokal terenkripsi.
- Penyimpanan kredensial menggunakan penyimpanan aman perangkat.
- Opsi memblokir screenshot dan pratinjau aplikasi terbaru.
- Audit log untuk aktivitas keamanan dan operasi penting.

Detailnya dijelaskan di [SECURITY.md](SECURITY.md).

### Banyak profil
Aplikasi mendukung beberapa profil. Data, pengaturan, database, dan sebagian kredensial keamanan dibuat terpisah berdasarkan profil.

Hal ini berguna ketika satu perangkat digunakan untuk lebih dari satu konteks keuangan.

### Bahasa dan mata uang
Antarmuka menyediakan bahasa Indonesia dan Inggris.

Tampilan nominal mendukung IDR, USD, EUR, JPY, SGD, dan MYR. Data keuangan tetap menggunakan basis IDR; nilai tukar digunakan untuk kebutuhan tampilan dan input.

## Privasi dan penyimpanan data

Kaji Finance dirancang agar data keuangan utama dapat digunakan secara lokal tanpa ketergantungan pada cloud.

Namun, **backup yang Anda ekspor menjadi file biasa di luar perlindungan database aplikasi**. Jika file backup dikirim melalui aplikasi lain, disimpan di cloud, atau dibagikan kepada orang lain, keamanannya juga bergantung pada tempat tersebut.

PIN aplikasi tidak dimasukkan ke dalam backup. Setelah backup dipulihkan, perlindungan PIN pada perangkat tujuan perlu diaktifkan kembali.

## Teknologi

Project ini merupakan aplikasi Flutter untuk Android.

Beberapa komponen penting yang digunakan:
- Flutter dan Dart.
- SQLite dengan SQLCipher untuk database terenkripsi.
- Flutter Secure Storage untuk data keamanan.
- Local Auth untuk biometrik.
- Shared Preferences untuk pengaturan non-rahasia.
- Provider untuk pengelolaan state aplikasi.
- File Picker dan Share untuk pertukaran berkas.
- Local notifications untuk pengingat.

## Pengujian

Repository menyediakan pengujian untuk bagian penting seperti:
- Model data.
- Transaksi.
- Hutang.
- Tagihan rutin.
- Target tabungan.
- Impor transaksi.
- Backup dan restore.
- Autentikasi dan lockout.
- Audit log.
- Transaksi database.
- Profil.
- Format uang.
- Widget dan teks aplikasi.

CI juga menjalankan analisis Flutter dan proses build Android release.

## Untuk pengguna awam

Jika tujuan Anda hanya mengatur keuangan pribadi, Anda tidak perlu memahami Flutter, database, atau kriptografi.

Cara penggunaan sederhananya:

1. Buat profil dan atur nama akun.
2. Buat satu atau beberapa dompet.
3. Catat pemasukan dan pengeluaran setiap kali terjadi.
4. Buat anggaran untuk kategori yang ingin dikontrol.
5. Buat target tabungan bila memiliki tujuan tertentu.
6. Catat hutang dan tagihan rutin bila diperlukan.
7. Gunakan halaman analisis untuk melihat pola keuangan.
8. Buat backup secara berkala dan simpan backup di tempat yang aman.
9. Aktifkan PIN atau biometrik untuk melindungi aplikasi.

## Catatan penting

Kaji Finance adalah alat pencatatan dan pengelolaan keuangan pribadi. Hasil analisis aplikasi bergantung pada kelengkapan dan kebenaran data yang Anda masukkan.

Aplikasi bukan layanan bank, bukan dompet digital, dan tidak memindahkan uang secara langsung.

## Lisensi

Informasi lisensi mengikuti berkas lisensi yang tersedia di repository.
