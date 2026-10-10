# MacRAR Plus 2.1.0 (4): derin inceleme

Durum güncellemesi: bu altı sorun grubu 2.1.1 (5) içinde giderildi; TAR'ın iki nedeni de düzeltildi. [Düzeltmeler ve doğrulama](2.1.1.tr.md). Aşağıdaki metin düzeltme öncesi incelemenin tarihsel kaydıdır.

9 Ekim 2026. Bu turda altı ek sorun doğrulandı. TAR bulgusunun iki ayrı nedeni var. Uygulamanın üretim kaynakları ve dağıtım paketleri bu inceleme sırasında değiştirilmedi; bulgular henüz düzeltilmedi.

İnceleme, arşiv motoru çıktılarının ayrıştırılması, çıkarma ve çakışma politikaları, arşiv değişikliklerinin doğrulanması, kaynakların Çöp Sepeti'ne taşınması, görev yönetimi, pencere yaşam döngüsü ve paketleme kodunu kapsadı. Deneyler ayrı `artifacts/deep-audit/run-*` klasörlerinde yapıldı. Kaynaklardan derlenen deney programı uygulamanın paketlediği arşiv motorlarını kullandı. Pencere sorunu gerçek uygulamada tekrarlandı ve işlem örneklemesiyle doğrulandı.

## 1. P1 — Çıkarmada yeniden adlandırılan dosya başka bir girdinin altında kalıyor

İlgili kod: [ArchiveSafety.swift:169](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:169), [ArchiveSafety.swift:174](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:174), [ArchiveSafety.swift:177](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:177).

Hedefte `item` adlı dosya var. Arşivde `item` ve `item 2` bulunuyor. Kullanıcı mevcut `item` için yeniden adlandırmayı seçiyor. `item` önce işlenirse adı `item 2` oluyor; ardından arşivden gelen gerçek `item 2`, varsayılan üzerine yazma politikasıyla az önce çıkarılan dosyayı eziyor. Çıkarma işlemi hata vermeden bir girdinin içeriğini kaybediyor.

Üretimdeki `ArchiveSafety.commit` çağrısıyla iki farklı kaynak oluşturma sırası denendi. Her iki denemede de işleme sırası `item`, `item 2` oldu ve sonuç yalnızca `item=old target`, `item 2=incoming B` kaldı. `incoming A` kayboldu. Bu sonuç, aynı adın her platformda aynı sırada işleneceği iddiası değildir; mevcut dosya sistemi üzerinde veri kaybını tetikleyen sıra tekrarlandı.

Gerekli düzeltme: tüm gelen yolları ve yeniden adlandırma sonuçlarını taşımadan önce planlamak, aynı işlemde ayrılan adları da benzersizlik kontrolüne dahil etmek. Gerileme kontrolü üç içeriğin de korunmasını ve sıradan bağımsız sonucu doğrulamalı.

## 2. P2 — Kaynak doğrulaması aynı boyut ve tarihle değiştirilen içeriği kaçırıyor

İlgili kod: [SourceManifest.swift:5](/Volumes/HIKSEMI/MacRAR-Plus/Sources/SourceManifest.swift:5), [SourceManifest.swift:48](/Volumes/HIKSEMI/MacRAR-Plus/Sources/SourceManifest.swift:48), [Operations.swift:431](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:431), [Operations.swift:435](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:435).

“Doğrulamadan sonra kaynakları Çöp Sepeti'ne taşı” seçeneği kaynak dosyaları yalnızca yol, boyut ve değişiklik tarihiyle karşılaştırıyor. Arşiv oluşturulduktan sonra kaynak aynı uzunlukta başka içerikle değiştirilir ve eski tarihi korunursa doğrulama geçiyor. Arşiv eski içeriği taşıdığı halde güncel kaynak otomatik taşımaya uygun kabul ediliyor.

Deneyde `original bytes` arşivlendi; kaynak atomik olarak `replaced bytes` ile değiştirildi ve başlangıçta kullanılan sabit değişiklik tarihi geri verildi. Her iki içerik 14 bayt. Gerçek kaynak dosyası ve arşiv üzerinde `SourceManifest.verify` hata vermedi. Bu turda Çöp Sepeti'ne taşıma yapılmadı; doğrulamanın bu değişikliği kaçırdığı tekrarlandı ve ardından çalışan taşıma kodu incelendi. Bu seçenek kalıcı silme yapmıyor, kaynak Çöp Sepeti'nden kurtarılabilir; yine de arşivin güncel içeriğin yedeği olduğu güvencesi sağlanmıyor.

Gerekli düzeltme: yalnızca bu kaynak temizleme seçeneğinde içerik doğrulaması yapmak ve doğrulama ile taşıma arasındaki dosya değişimini de ele almak. Kaynak kimliği, boyutu ve tarihi yardımcı kontroller olabilir, ancak içerik eşitliği yerine geçmez. Gerileme kontrolü tarih korunan içerik değişikliğinde kaynağı yerinde bırakmalı.

## 3. P2 — Oluşturma penceresinin kırmızı kapatma düğmesi görünmeyen modal beklemeyi bırakıyor

İlgili kod: [Dialogs.swift:516](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Dialogs.swift:516), [Dialogs.swift:702](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Dialogs.swift:702), [Dialogs.swift:715](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Dialogs.swift:715).

Yeni arşiv için dosya seçildikten sonra “Arşiv Oluştur” seçenek penceresi kırmızı kapatma düğmesiyle kapatıldı. Pencere kayboldu, fakat `NSApp.runModal(for:)` dönmedi. Normal pencere kapatma ve uygulamadan çıkma kısayolları yanıt vermedi; uygulama menüsünde Çık öğesi devre dışı kaldı. “İptal” ve onay düğmeleri modal döngüyü durduruyor; pencere kapatma yolu bunu yapmıyor.

İşlem örneklemesinde ana iş parçacığı, pencere kapandıktan sonra hâlâ `CompressDialog.run → NSApplication.runModalForWindow → _NSTryRunModal` içinde bekliyordu. Erişilebilirlik üzerinden doğrudan bazı düğmeleri çağırabilmek normal klavye/menu yönlendirmesinin çalıştığını göstermedi. Takılmış test uygulaması sonlandırılıp normal açılış durumuna yeniden getirildi; arşiv oluşturma işi başlatılmadı.

Gerekli düzeltme: pencere kapanışını modal iptal sonucuna bağlamak; kırmızı düğme, ⌘W, İptal ve uygulama çıkışını aynı yaşam döngüsüyle tamamlamak. Gerileme kontrolü kapatılan seçenek penceresinden sonra normal kısayolların çalıştığını doğrulamalı.

Kanıt: [native-sample.txt](/Volumes/HIKSEMI/MacRAR-Plus/artifacts/deep-audit/native-sample.txt).

## 4. P2 — Normal TAR arşivleri iki ayrı kontrol nedeniyle çıkarılamıyor

İlgili kod: [RarEngine.swift:356](/Volumes/HIKSEMI/MacRAR-Plus/Sources/RarEngine.swift:356), [ArchiveSafety.swift:24](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:24), [ArchiveSafety.swift:59](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:59), [ArchiveSafety.swift:89](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:89).

Birinci neden: paketli 7-Zip motoru TAR içindeki sıradan dosyalarda da boş `Symbolic Link =` ve `Hard Link =` alanları yazıyor. Ayrıştırıcı boş metni `linkTarget` olarak saklıyor; güvenli çıkarma kontrolü bunu gerçek bir bağlantı sanıp reddediyor. `a.txt` içeren, bağlantısız ve Apple ek metadatası olmayan standart ustar arşiviyle `Ops.extract` başarısız oldu.

İkinci neden: `tar ... -C kaynak .` ile oluşturulan yaygın TAR yapısı `.` ve `./a.txt` girdileri içeriyor. Deneyde yalnızca boş bağlantı alanları bellek içinde temizlendi; üretim kodu değiştirilmedi. Bu kez `.` hedef klasörün kendisine karşılık geldiği için “hedefin dışına yazma” kontrolünde reddedildi. Ayrıca çıkarılan yol kümesinin karşılaştırılmasında `./a.txt` ve `a.txt` için ortak normalleştirme eksikliği kodda mevcut; bu son karşılaştırmaya deneyde ulaşılmadı, çünkü önce kök yol kontrolü durdurdu.

Gerekli düzeltme: boş bağlantı alanlarını bağlantı yok şeklinde yorumlamak; güvenli göreli TAR yollarını tutarlı normalleştirmek; `.` kök dizin girdisini özel ele almak. Gerçek bağlantılar, mutlak yollar ve `..` içeren yollar için korumalar korunmalı. Normal ve `./` önekli TAR senaryoları ayrı test edilmeli.

## 5. P2 — Dosya adı şifre hatası sanılıyor

İlgili kod: [RarEngine.swift:63](/Volumes/HIKSEMI/MacRAR-Plus/Sources/RarEngine.swift:63), [RarEngine.swift:251](/Volumes/HIKSEMI/MacRAR-Plus/Sources/RarEngine.swift:251).

Şifresiz ZIP içine sırasıyla `Wrong password.txt`, `Incorrect password.txt` ve `Enter password.txt` konuldu. Motor üçünde de başarılı çıkış kodu `0` verdi; uygulamanın listeleme sonucu üçünde de `wrongPassword` oldu. Kontrol tüm çıktı içinde bu sözcükleri aradığı için arşiv girdisinin adını hata mesajından ayıramıyor. Listeleme ve şifre isteme akışı yanlış yönleniyor.

Gerekli düzeltme: başarılı motor sonucu ile hata tanımını ayırmak; hata çıktısını motorun gerçek hata satırları/kodları üzerinden değerlendirmek. Bu dosya adları şifresiz ZIP listeleme testine eklenmeli; gerçek yanlış şifre de ayrı doğrulanmalı.

## 6. P2 — RAR içindeki son dosya silinemiyor

İlgili kod: [Operations.swift:525](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:525), [Operations.swift:526](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:526).

Yalnızca `last.txt` içeren RAR'da bu dosya seçilip üretimdeki `Ops.delete` çalıştırıldı. RAR motoru son girdi silindiğinde geçici arşivi kaldırıyor. İşlem sonrası doğrulama var olmayan dosyayı listelemeye çalışıp başarısız oluyor; asıl arşiv korunuyor ve silme yapılamıyor. Deney sonucu `success=false, original preserved=true`. Bu bulguda veri kaybı yok.

Gerekli düzeltme: son girdi silme durumunun ürün davranışını açıkça tanımlamak ve doğrulamayı buna göre yapmak. Asıl arşivi sessizce silmek uygun bir düzeltme olmaz; desteklenen boş arşiv davranışı veya kullanıcının açıkça seçebileceği arşivi kaldırma akışı gerekir.

## Deney çıktısı ve kapsam

Deney programı: [main.swift](/Volumes/HIKSEMI/MacRAR-Plus/artifacts/deep-audit/main.swift). Son tamamlanan çalışma: [results-3.txt](/Volumes/HIKSEMI/MacRAR-Plus/artifacts/deep-audit/results-3.txt).

```text
PASSWORD name=Wrong password.txt, engineExit=0, outcome=wrongPassword
PASSWORD name=Incorrect password.txt, engineExit=0, outcome=wrongPassword
PASSWORD name=Enter password.txt, engineExit=0, outcome=wrongPassword
RENAME order=["item", "item 2"], output=["item=old target", "item 2=incoming B"]
RENAME order=["item", "item 2"], output=["item=old target", "item 2=incoming B"]
MANIFEST changed contents with same size/date accepted=true
DOT TAR names=[".", "./a.txt"]
DOT TAR production extraction=false
PLAIN TAR links=[Optional("")]
PLAIN TAR production extraction=false
DOT TAR after empty-link metadata correction extraction=false
DELETE LAST RAR success=false, original preserved=true
ENCRYPTED 7Z beforeProtected=true, cachedPasswordReloadHeadersEncrypted=false, addSuccess=true, afterProtected=true
IDLE at completion
```

Şifreli 7z'de önbellekteki şifreyle yeniden listeleme sonrası `headersEncrypted` bilgisi yanlış görünse de gerçek motor dosya adı şifrelemesini ekleme işleminden sonra korudu. Bu nedenle şifreleme kaybı bulgusu olarak raporlanmadı. Önizleme penceresinin kapanışında görülen kısayol sorunu da gizli oluşturma modalinden kaynaklandığından ayrı önizleme hatası sayılmadı.

Önceki 122 kontrol bu yeni senaryoları kapsamıyor. Bu turda üretim kodu değişmediği için yeni dağıtım oluşturulmadı. CPU/GPU/pil tüketimi için yeni ölçüm, başka diske büyük dosyalı Finder aktarımı zaman ölçümü, macOS 13 çalışma testi ve Intel testi yapılmadı; bu alanlarda sonuç garantisi verilmez.

## Önceki açık bulgular

[Önceki ek inceleme](/Volumes/HIKSEMI/MacRAR-Plus/docs/plus/REVIEW-FOLLOWUP-2026-10-09.tr.md) içindeki seçilmemiş dosyaların joker karakterle arşive eklenmesi ve dış editör kaydının daha yeni arşiv içeriğini ezmesi doğrulanmış, henüz düzeltilmemiş sorunlar. Finder'a son aktarımın ana kuyrukta çalışması ise kod incelemesine dayalı performans riski; büyük dosyalı çalışma ölçümüyle doğrulanmadı.

İki rapor birlikte sekiz deneyle doğrulanmış sorun grubunu ve bir statik performans riskini içeriyor. İlk düzeltme önceliği dosya içeriğini koruyan çıkarma/ekleme/kayıt akışları; ardından kaynak temizleme doğrulaması ve diğer işlev hataları olmalı.
