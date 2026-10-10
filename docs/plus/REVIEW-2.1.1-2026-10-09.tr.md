# MacRAR Plus 2.1.1 (5): ek inceleme

**Durum — 2.1.2:** Bu rapordaki beş doğrulanmış bulgu toplu düzeltme sürümünde kapatıldı. Tekrarlanabilir regresyonlar `Tests/ConsolidatedRegressions.swift` içindedir. [Düzeltme ve doğrulama notları](2.1.2.tr.md). Aşağıdaki kayıt düzeltme öncesi incelemeyi açıklar.


Bu incelemede beş ek sorun doğrulandı. Üretim kaynakları ve DMG/ZIP paketleri değiştirilmedi; aşağıdaki sorunlar henüz düzeltilmedi. Önceki 217 kontrolün geçmesi bu yeni senaryoları kapsadığı anlamına gelmiyor.

Deneyler, mevcut üretim kaynaklarından derlenen ayrı program ve paketlenen motorlarla, yalnızca `artifacts/audit-2.1.1/run-*` altındaki test dosyalarında yapıldı. Kaynakları Çöp Sepeti'ne taşıma seçeneği kullanılmadı; kullanıcının çalışma dosyalarına dokunulmadı.

## 1. P1 — Parçalı RAR oluşturma mevcut arşiv parçalarını eziyor

İlgili kod: [Operations.swift:369](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:369), [Dialogs.swift:442](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Dialogs.swift:442), [Dialogs.swift:445](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Dialogs.swift:445).

Oluşturma öncesi kontrol yalnızca seçilen `split.rar` yoluna bakıyor. Parçalı çıktının gerçek adı `split.part1.rar`, devamı `split.part2.rar` vb. Bu parçalar mevcutken `split.rar` bulunmadığı için kullanıcıya çakışma sorulmuyor. RAR motorunun `-y` seçeneği mevcut parçaların yerine yenilerini yazmasına izin veriyor.

Deneyde önce 32 KiB rastgele veriden 10 KiB parçalı geçerli RAR oluşturuldu. İlk parça üretimdeki listeleme yoluyla okunabildi. Kaynak başka içerikle değiştirildi; aynı taban adla `Ops.compress` çalıştırıldı. İşlem başarılı sonuçlandı, mevcut ilk parçanın baytları değişti. Sonuç bozuk olmak zorunda değil: sorun, kullanıcının eski arşivinin onaysız değiştirilmesi.

ZIP ve 7z'nin mevcut `.001` dosyasıyla aynı denemesinde motorlar işlemi reddetti ve dosyayı korudu. Bu nedenle onaysız üzerine yazma bulgusu bu deneyde yalnızca RAR için raporlanıyor.

Gerekli düzeltme: tüm çıktı ailesi için çakışma kontrolü; boş bir geçici konumda tüm parçaları oluşturma ve sonuçları güvenli biçimde yayımlama. Bir parçanın bulunması halinde arşiv ailesi için yeni ad veya açık çakışma kararı gerekir. Var olan parçalar deneyde bayt düzeyinde korunmalı.

## 2. P1 — Tarihi, boyutu ve dosya kimliği korunarak değiştirilen arşiv ezilebiliyor

İlgili kod: [FileRevision.swift:5](/Volumes/HIKSEMI/MacRAR-Plus/Sources/FileRevision.swift:5), [Operations.swift:613](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:613), [Operations.swift:634](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:634).

2.1.1 normal dış arşiv değişikliklerini başlangıç revizyonuyla karşılaştırıp reddediyor. Ancak revizyon yalnızca boyut, değişiklik tarihi ve inode içeriyor. Mevcut dosyaya yerinde yazılarak eşit uzunlukta başka geçerli arşiv konur ve eski değişiklik tarihi korunursa bu üç alan değişmiyor; gerçek içerik değişikliği kaçıyor.

Deneyde aynı dosya adı ve sabit dosya tarihleriyle oluşturulmuş iki geçerli, sıkıştırmasız ZIP kullanıldı. İçerikler `original bytes` ve `replaced bytes`; arşivlerin byte uzunluğu aynı. Arşivin başlangıç değişiklik tarihi de sabit bir tam saniyeye ayarlandı. Yeni ZIP baytları mevcut arşive `FileHandle` ile yazıldı, inode korundu ve tarih geri verildi. `FileRevision` eşit kaldı; yeni arşiv okunabildi. Eski listeye bağlı editör kaydı başarılı sonuçlanırken dışarıdan gelen arşiv baytları korunmadı.

Bu durum kaynak temizliğindeki SHA-256 kontrolünün yeniden bozulduğu anlamına gelmez; kaynak temizliği ve arşiv düzenleme revizyonları farklı kontroller kullanıyor. Şartları açıkça aynı boyut, aynı inode ve korunmuş tarih olan bir arşiv düzenleme açığıdır.

Gerekli düzeltme: düzenleme başlangıcını ve kayıttaki arşiv içeriğini karşılaştırabilen doğrulama. Yalnızca metadata, içerik eşitliği güvencesi değildir. Kontrol normal kullanımda boşta çalışan bir izleyici gerektirmez; düzenleme/kayıt sınırlarında yapılabilir.

## 3. P2 — Aynı adlı iki kaynak RAR'dan tek dosya olarak çıkıyor

İlgili kod: [Dialogs.swift:442](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Dialogs.swift:442), [ArchiveSafety.swift:104](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:104), [ArchiveSafety.swift:117](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveSafety.swift:117).

Farklı klasörlerden `A/report.txt` ve `B/report.txt` seçiliyor. İçerikleri `source A` ve `source B`; ikisi de aynı boyutta. RAR oluşturma `-ep1` ile iki girdiyi de `report.txt` arşiv yolunda saklıyor. Arşiv listesinde aynı yol iki kez var.

Varsayılan üretim çıkarma yolunda motor aynı hedef dosyaya iki kez yazıyor. Çıkarma sonrası doğrulama yolları `Set` ile karşılaştırdığı için iki girdi ile tek çıktı arasındaki farkı kaybediyor; boyutlar eşit olduğundan boyut kontrolü de geçiyor. Sonuç başarı, fakat hedefte yalnızca `report.txt=source B` var.

İki kaynak içerik de RAR'ın içinde bulunuyor; bu deney orijinal kaynak dosyaları silmedi. Sorun, uygulamanın standart çıkarma akışında iki girdiyi ayrı ayrı koruyamaması ve buna rağmen başarı bildirmesi. ZIP, 7z ve TAR oluşturma aynı girdileri motor hatasıyla reddetti; onların sessiz içerik kaybettiği iddia edilmiyor.

Gerekli düzeltme: oluştururken çakışan arşiv yollarını engellemek veya ayrı klasörleri korumak. Dışarıdan gelen arşivlerde de yinelenen/aynı hedefe eşlenen girdiler çıkarılmadan önce ele alınmalı; yol kümesi ve boyut kontrolü tek başına yeterli değil.

## 4. P2 — Parçalı arşiv oluşturma var olmayan çıktı yolunu bildiriyor

İlgili kod: [Operations.swift:460](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:460), [ArchiveWindow.swift:475](/Volumes/HIKSEMI/MacRAR-Plus/Sources/ArchiveWindow.swift:475).

Yeni ve çakışmasız hedeflerde ZIP, 7z ve RAR için parçalı oluşturma başarılı oldu. Tamamlama yolu ise sırasıyla `fresh-split.zip`, `fresh-split.7z`, `fresh-split.rar` kaldı; bu üç dosya da yok. Gerçek dosyalar `.001` veya `.part1.rar` ile başlıyor.

Oluşturma penceresi tamamlama yolunu hemen `openArchive`'a verdiğinden sonraki açma adımı var olmayan dosyaya yönleniyor. Motor başarılı olsa bile kullanıcı akışı hata veriyor. Bu bulgu, mevcut parçaların üzerine yazılmasıyla aynı sorun değil: tamamen yeni hedeflerde de oluşuyor.

Gerekli düzeltme: tamamlama ve geçmiş kaydı gerçek ilk arşiv parçasını bildirmeli; sonrasında ilk parça açılabilmeli ve tüm parçalar korunmalı.

## 5. P3 — Geçerli boş RAR çıkarma işlemi hata sayılıyor

İlgili kod: [Operations.swift:261](/Volumes/HIKSEMI/MacRAR-Plus/Sources/Operations.swift:261).

2.1.1'in son dosya silme düzeltmesinde kullanılan `RarRunner.writeEmptyRAR` ile geçerli bir boş RAR oluşturuldu. Listeleme başarılıydı. `Ops.extract` çalıştırıldığında UNRAR “No files to extract” ve çıkış kodu 10 verdi; uygulama bunu başarısız çıkarma saydı.

Boş RAR'ın bütünlük testi ve yeniden ekleme önceki kontrollerde geçiyor; bu yeni bulgu yalnızca çıkarma davranışıyla ilgili. Veri kaybı yok. Toplu çıkarma da aynı `Ops.extract` yolunu kullanıyor; toplu işlemde başarısız etiketlenmesi kod yolu üzerinden beklenir, bu turda ayrı toplu UI deneyi yapılmadı.

Gerekli düzeltme: güncel arşivin gerçekten boş olduğu doğrulanmışsa çıkarma işlemini uygun bir boş sonuç olarak tamamlamak. UNRAR kodu 10 genel olarak başarıya çevrilmemeli; yanlış seçilmiş veya bulunmayan dosyalarda da kullanılabilir.

## Kanıt ve sınırlar

Deney programı: [main.swift](/Volumes/HIKSEMI/MacRAR-Plus/artifacts/audit-2.1.1/main.swift). Sonuçlar: [results-3.txt](/Volumes/HIKSEMI/MacRAR-Plus/artifacts/audit-2.1.1/results-3.txt) ve tekrar çalışması [results-4.txt](/Volumes/HIKSEMI/MacRAR-Plus/artifacts/audit-2.1.1/results-4.txt).

```text
DUPLICATE RAR 5 success=true, names=["report.txt", "report.txt"]
DUPLICATE extracted=true, files=["report.txt"], content=source B
SPLIT RAR existingValidFirstVolume=true
SPLIT RAR 5 success=true, existingVolumePreserved=false, reportedPathExists=false
FRESH SPLIT 7z success=true, reportedPathExists=false
FRESH SPLIT ZIP success=true, reportedPathExists=false
FRESH SPLIT RAR 5 success=true, reportedPathExists=false
REVISION equalArchiveSize=true
REVISION equalMetadata=true, newArchiveReadable=true
REVISION saveSuccess=true, externalArchiveBytesPreserved=false
EMPTY RAR extractSuccess=false
IDLE=true
```

İlk küçük parçalı RAR denemesi gerçekten bölünecek kadar büyük veri kullanmadığı için üzerine yazmayı tetiklemedi; son deneyler 32 KiB sıkıştırılamayan veri kullanıyor. Arşiv revizyonu denemesindeki zaman hassasiyeti, sabit başlangıç tarihiyle giderildi. Önceki normal revizyon koruması çalışmayı sürdürüyor; bu inceleme yeni koşullu açığı gösteriyor.

Bu tur yeni CPU/GPU/pil ölçümü veya başka işletim sistemi testi yapılmadı. Üretim kaynakları değiştirilmediği için yeni sürüm/paket hazırlanmadı.
