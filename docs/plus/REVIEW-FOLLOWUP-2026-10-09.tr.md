# MacRAR Plus 2.1.0 (4): ek inceleme

Durum güncellemesi: bu üç bulgu 2.1.1 (5) içinde giderildi. ZIP/7z için tam ad seçimi; RAR joker yollarında güvenli durdurma; editör oturumu revizyonu; Finder yerleştirmesinin arka kuyruğa alınması doğrulandı. [Düzeltmeler ve doğrulama](2.1.1.tr.md). Aşağıdaki metin düzeltme öncesi incelemenin tarihsel kaydıdır.

Bu incelemede uygulama kaynakları değiştirilmedi. Aşağıdaki ilk iki hata mevcut kaynaklardan derlenen ayrı bir deney programı ve uygulamanın paketlediği arşiv motorlarıyla tekrarlandı. Üçüncü bulgu kod incelemesine dayanır. Güncel DMG bu sorunların düzeltmesini henüz içermez.

## P1 — Seçilmeyen dosyaların arşive eklenmesi

`literal*.txt` ve `literalABC.txt` aynı klasördeyken yalnızca ilk dosyanın yolunu seçmek, diğer dosyayı da arşive alır. `CompressOptions.buildSteps` ile ZIP, RAR ve TAR.GZ oluşturma; `Ops.add` ile mevcut ZIP'e ekleme denemelerinde doğrulandı. Bu, kullanıcının paylaşmak istemediği dosyaları arşive dahil edebilir.

İlgili yerler: `Sources/Dialogs.swift:432`, `Sources/Dialogs.swift:442`, `Sources/Dialogs.swift:471`, `Sources/Operations.swift:486`, `Sources/Operations.swift:488`. Silme akışındaki RAR joker karakter koruması bu işlemleri kapsamıyor. 7-Zip için dosya seçiminde joker yorumlamasını kapatma; RAR için tam ad seçim desteğini doğrulama veya güvenli şekilde reddetme gerekiyor. Klasörün kendisini seçmekle tek dosyayı seçmek arasındaki kapsam da test edilmeli.

## P1 — Dış editör kaydı daha yeni arşiv içeriğini ezebiliyor

Arşiv listesi alınır; dosya dış editörde düzenlenir; başka bir uygulama arşivde aynı dosyayı değiştirir; eski listeyle `Ops.saveEdited` çalıştırılır. İşlem başarılı sonuçlanırken diğer uygulamanın yeni içeriğinin yerini yerel editör kopyası alır.

İlgili yerler: `Sources/Operations.swift:558`, `Sources/Operations.swift:570`, `Sources/Operations.swift:590`. Mevcut revizyon kontrolü kayıt başladığından sonraki değişiklikleri yakalar. Düzenleme için dosya açıldığı andan kayıt başlayana kadar arşivde yapılan değişikliği yakalamaz. Düzenlenecek arşiv girdisinin başlangıç sürümüyle güncel sürümü karşılaştırılmalı; anlaşmazlıkta kaynak arşiv korunmalıdır. Birden çok dosyanın sırayla kaydedilmesi de bu kontrole dahil edilmelidir.

## P2 — Finder sürükle-bırak aktarımı ana kuyrukta

`Sources/ArchiveWindow.swift:943` ana kuyruk bloğundaki `moveIntoPlace`, `Sources/ArchiveWindow.swift:962` üzerinden senkron `ArchiveSafety.place` çağırır. Farklı diske aktarım `Sources/ArchiveSafety.swift` içinde `copyItem` kullanır. Büyük dosyaların başka diske kopyalanması arayüz kuyruğunu bloke edebilir. Bu bulgu kod yolu üzerinden saptandı; büyük dosyalı UI zaman ölçümü yapılmadı. Son aktarım arka planda çalıştırılmalı, UI durumu ve vaat tamamlama işlemleri güvenli şekilde koordine edilmelidir.

## Deney çıktısı

Kaynak: `artifacts/audit-probe/main.swift`; sonuç: `artifacts/audit-probe/results.txt`.

```text
CREATE zip selected literal*.txt -> ["literal*.txt", "literalABC.txt"]
CREATE rar selected literal*.txt -> ["literal*.txt", "literalABC.txt"]
CREATE tar.gz selected literal*.txt -> ["literal*.txt", "literalABC.txt"]
ADD ZIP success=true -> ["literal*.txt", "literalABC.txt", "seed.txt"]
STALE EDITOR success=true, external archive bytes preserved=false, document=local editor edit
```

Önceki 122 kontrolün geçmesi bu senaryoların güvenli olduğunu göstermiyor; bunlar test kapsamındaki boşluklardır. Deney, çalışma dosyalarından ayrı `artifacts/audit-probe/run-*` klasöründe yürütüldü.
