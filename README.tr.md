# MacRAR Plus

**2.3.1:** [Yeni özellikler ve doğrulama notları](docs/plus/2.3.1.tr.md). Daha sade ana ekran, Önizle/Sıkıştır/Çıkart işlemleri, isteğe bağlı dosya bilgileri ve kolay sıkıştırma penceresi. Arşiv haritası, gelişmiş arama, dosya listesi aktarımı ve Finder eylemleri kullanılmaya devam eder.

MacRAR'ın arşiv motorunu koruyan, Mac için geliştirilmiş bir sürüm. Swift/AppKit dosya listesi, SwiftUI çalışma alanı ve yerel Quick Look önizlemesi kullanır. Dosyalar ağ üzerinden gönderilmez.

MacRAR Plus geliştiricisi: [BerkDrmz](https://github.com/BerkDrmz).

Apple Silicon/macOS 13+ için **2.3.1** sürümü: [ZIP/DMG indir](https://github.com/BerkDrmz/MacRAR-Plus/releases/tag/v2.3.1). `./package.sh` ile aynı paket biçimleri `dist/` altında hazırlanır.

Özgün kaynak kodun telif bildirimleri ve MIT lisansı [LICENSE](LICENSE) dosyasında korunur.

## Başlatma

Apple Silicon, macOS 13+ gerekir. Bu yerel paket ad-hoc imzalıdır; Apple Developer ID ile imzalanmış ve notarize edilmiş bir dağıtım değildir.

```sh
open "build/MacRAR Plus.app"
```

Hazır ZIP/DMG paketleri `dist/` içinde bulunur. DMG içinden uygulamayı Applications klasörüne sürükleyebilirsiniz. Finder hızlı eylemleri uygulama menüsünden ayrıca kurulabilir. Varsayılan arşiv uygulamasını değiştirmek uygulama menüsünden seçilir.

## Kolay kullanım

1. **Aç** ile arşivi seçin. Dosya türü filtresi listenin üstündeki **Tüm dosyalar** menüsündedir.
2. Dosya seçince alttaki **Önizle**, **Sıkıştır…** ve **Çıkart…** düğmeleri kullanılır. Seçim yoksa **Çıkart…** tüm dosyaları seçtiğiniz klasöre çıkartır. **Yeni arşiv…** bilgisayarınızdan dosya seçtirir.
3. **Diğer** menüsünden dosya bilgileri, dosya ekleme, bütünlük testi, arşiv haritası, CSV/JSON aktarımı, toplu işlemler ve geçmiş açılır.

Sıkıştırma penceresi ilk olarak konum ve biçimi gösterir. Şifre için **Şifreyle koru** seçeneğini açın. Profil, sıkıştırma seviyesi, parçalara bölme ve diğer ayrıntılar **Gelişmiş seçenekler** altında bulunur. Finder’da sağ tık → Hızlı Eylemler → **MacRAR Plus • Sıkıştır…** aynı pencereyi açar.

## Eklenenler

- **Arşiv haritası (⇧⌘M):** arşivi çıkarmadan en büyük dosyaları ve türlerin toplam açılmış boyutunu gösterir. Aynı boyut/CRC32’ye sahip dosyaları tekrar adayı olarak gruplar; kesin kopya olduğunu iddia etmez ve otomatik silmez. **Listede bul** dosyayı arşivde seçer. Ekranda ilk 50 dosya/tür/grup, her grupta ilk 20 üye gösterilir; toplamlar bütün arşivi kapsar.
- **İfade ve hariç tutma araması:** `"yıllık rapor" -yedek ext:pdf type:file encrypted:no`. `size>10MB`, `after:2026-01-01` ve `before:2026-12-31` ile birlikte çalışır. `*` ve `?` gerçek karakterdir. Araçlar menüsünde arama rehberi ve büyük/boş/şifreli dosya aramaları bulunur. **⇧⌘F** arama ve kategoriyi temizler.
- **CSV/JSON dosya listesi:** Dosya menüsünden seçili öğeleri ve seçili klasörlerin tüm içeriğini; seçim yoksa filtreye uyan kayıtları aktarır. CSV’de formül benzeri metinler güvenli hale getirilir; JSON’da adlar aynen korunur. Arşiv ve bilinen parçalarının üzerine kayıt engellenir.
- **Pratik işlemler:** dosya adı/yol kopyalama ve arşivi Finder’da gösterme.
- Son açılan arşivlerle başlangıç ekranı, sürükle-bırak, sistem açık/koyu görünümü.
- Belge, görsel, ses/video, kod/veri ve şifreli öğe filtreleri; filtreyle birlikte çalışan yol araması.
- Sıralanabilir sütunlar; başlığa sağ tıklayarak tarih ve CRC32 sütunlarını gösterme.
- **Diğer → Dosya bilgilerini göster / gizle** ile açılan dosya/çoklu seçim bilgi paneli. Dar pencerede listeye alan bırakmak için gizlenir.
- Tek dosyayı seçip **Boşluk** veya **⌘Y** ile yerel Quick Look önizlemesi.
- Toplu çıkarma ve bütünlük testi kuyruğu (**⇧⌘B**). Her arşiv ayrı klasöre çıkarılır, mevcut klasörlere sessizce karıştırılmaz. Kuyruk mevcut işlemden sonra durdurulabilir; işlem penceresinden çalışan iş iptal edilebilir.
- Yerel işlem geçmişi; son 100 işlemin sonucu ve Finder kısayolu.
- Arka planda arşiv listeleme; arayüz büyük arşiv okunurken yanıt vermeye devam eder.
- Önbelleklenen klasör toplamları ve sınırlandırılmış işlem günlükleri.
- Şifresiz oluşturma/eklemede yanlışlıkla şifre ekleyen komut seçenekleri düzeltildi. Yeni arşiv penceresi ücretsiz ZIP biçimiyle başlar.

## Arşiv ve veri koruması

Çıkarma öncesi yollar, boyut bilgisi, hedef bağlantılar ve boş disk alanı kontrol edilir. Motor önce yeni bir geçici klasöre çıkarır. Başarılı işlemden sonra çıkarılan öğeler kontrol edilerek hedefe aktarılır. Motor hatası veya iptal, bu geçici çıkarma klasörünü temizler. Çok dosyalı aktarım başarısız olursa değişmemiş çıktılar geri alınır ve eski hedef kopyaları yerine konur. Dış düzenleme veya dosya sistemi hatası geri almayı engellerse kurtarma kopyaları korunur ve konumları bildirilir.

Arşivdeki sembolik/sabit bağlantılar, özel dosyalar, mutlak yollar ve üst klasöre çıkan yollar bu sürümde reddedilir. Bağlantı içeren bazı uygulama/Unix paketleri bu yüzden açılamaz. Bu kontroller macOS sandbox yerine geçmez.

Arşive ekleme ve silme bir kopya üzerinde yapılır; motor başarılı olunca asıl arşiv değiştirilir. Büyük arşivler için aynı diskte kopyaya yetecek ek alan gerekir. Çok parçalı arşiv düzenleme sunulmaz.

“Kaynakları sil” seçeneği motorun erken silme seçeneğine gönderilmez. Tüm sıkıştırma aşamaları ve bütünlük testi başarılı olduktan sonra kaynaklar Çöp Sepeti'ne taşınır. Parçalı çıktı ile bu seçenek birlikte kullanılamaz.

## Biçimler

RAR (eski sürümler dahil), ZIP, 7z, TAR, TAR.GZ, TAR.XZ ve 7-Zip'in okuyabildiği diğer arşivler açılır. Şifreli arşivler ve çok parçalı RAR/7z arşivleri desteklenir. Oluşturma: RAR 5, ZIP, 7z, TAR, TAR.GZ, TAR.XZ, TAR.BZ2. RAR 7 motoru RAR 4 oluşturmadığından bu seçenek kaldırılmıştır; RAR 4 okumak desteklenir.

ZIP şifreleri bu motorda yazdırılabilir ASCII karakterleriyle sınırlıdır. Türkçe veya emojili şifreler için 7z seçin.

RAR oluşturma, RARLAB'ın deneme/lisans koşullarına tabidir. ZIP/7z/TAR oluşturma ücretsiz motor kullanır. Motor lisansları uygulamanın Resources klasörüne eklenir.

## Geliştirme

Xcode Command Line Tools ve Swift derleyicisi gerekir. Harici Swift/JavaScript paketi kullanılmaz.

```sh
./fetch-tools.sh   # resmi kaynaklardan RAR/UNRAR ve 7zz
./build.sh         # yerel .app
./test.sh          # gerçek arşivlerle regresyon testleri
./package.sh       # yerel ZIP ve DMG
```

`./build.sh install` uygulamayı `/Applications/MacRAR Plus.app` konumuna kopyalar ve Plus'a ait Finder hızlı eylemlerini kurar. Orijinal MacRAR'ın uygulama kimliği ve hızlı eylemleri ayrıdır. Developer ID/notarizasyon için kendi sertifikanız ve notarytool profilinizle `release.sh` kullanılabilir. Kaynak kod [GitHub deposunda](https://github.com/BerkDrmz/MacRAR-Plus) bulunur.

Testler Unicode dosya adlarını, bozuk arşivleri, yol taşmasını, bağlantıları, literal seçili dosya çıkarmayı, şifreli arşivleri, çok parçalı 7z'yi, güvenli aktarımı, ekleme/silmeyi, iptali, yedi oluşturma biçimini ve toplu kuyruğu çalıştırır.

![MacRAR Plus](docs/plus/Workspace.png)

![MacRAR Plus — Sıkıştırma](docs/plus/Compression.png)
