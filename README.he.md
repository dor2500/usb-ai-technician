<div dir="rtl">

<p align="center">
  <img src="docs/images/banner.svg" alt="USB AI Technician" width="100%">
</p>

<p align="center">
  <a href="README.md"><b>🇬🇧 English</b></a>
</p>

**USB AI Technician** הוא כלי לתחזוקת מחשבים שרץ מדיסק און קי. מחברים את ה-USB למחשב Windows, מריצים את `Start.cmd`, והכלי יכול:

1. **לנקות את המחשב**: הבינה המלאכותית מסמנת תוכנות מיותרות, אתם בוחרים מה להשאיר, והשאר מוסר.
2. **להתקין תוכנות** מתיקיית `Installers` שעל ה-USB, בהתקנה שקטה כשאפשר.
3. **לעדכן את Windows**, ואחר כך להשאיר אוטומטיים רק את עדכוני האבטחה.

המודל הוא [gpt-oss-20b](https://huggingface.co/openai/gpt-oss-20b), והוא רץ מקומית בלי אינטרנט דרך [llama.cpp](https://github.com/ggml-org/llama.cpp), ונגיש רק מתוך המחשב עצמו (`127.0.0.1`). לא מותקן כלום על המחשב, והלוגים והגיבויים נשמרים על ה-USB.

<p align="center">
  <img src="docs/images/screen-cleanup.svg" alt="ניקוי: ה-AI ממליץ, אתם מחליטים" width="80%">
</p>

## התחלה מהירה

**מה צריך:** דיסק און קי של 32GB ומעלה, מפורמט ל-**exFAT או NTFS** (המודל שוקל 12GB, ו-FAT32 לא יכול לשמור קובץ כזה), ו-Windows 10 או 11 עם הרשאות מנהל. ה-AI צריך בערך 16GB זיכרון RAM, ובמחשבים חלשים יותר מריצים עם `-NoAI`.

1. **הכנת ה-USB (פעם אחת):** מחלצים את הגרסה האחרונה מ-[Releases](https://github.com/dor2500/usb-ai-technician/releases/latest) אל ה-USB (קובץ ה-`-with-llama.cpp` חוסך הורדה אחת), ומריצים את `Setup-USB.cmd`. הוא מוריד את llama.cpp ואת המודל ובודק את שניהם עם SHA-256.
2. **הוספת תוכנות להתקנה:** מעתיקים קבצי `.exe`, `.msi` או `.msix` אל `Installers\`. פרטים ב-[Installers/README.md](Installers/README.md).
3. **הפעלה:** במחשב היעד לוחצים פעמיים על `Start.cmd` ובוחרים מהתפריט: ניקוי, התקנה, עדכון, את שלושתם ברצף, שיחה עם ה-AI או ביטול נעילת העדכונים.

<div dir="ltr">

```powershell
Start.cmd -Action All    # also: Cleanup, Install, Update, UndoUpdateLock, Chat
Start.cmd -NoAI          # no model; you pick what to remove yourself
Start.cmd -DryRun        # show what would happen, change nothing
```

</div>

## איך זה עובד

- **ניקוי:** דרייברים, ספריות מערכת ותוכנות אבטחה אף פעם לא מוצעים להסרה ([`config/protected.json`](config/protected.json)). לפני שמשהו מוסר צריך להקליד `YES`, והכלי יוצר נקודת שחזור.
- **התקנה:** הכלי מזהה קבצי התקנה מסוג MSI, MSIX, Inno Setup, NSIS ו-WiX ומתקין אותם בשקט. קובץ שהסוג שלו לא מזוהה נפתח כרגיל.
- **עדכון:** הכלי מתקין את העדכונים הממתינים, ואחר כך נועל את גרסת Windows הנוכחית, חוסם עדכוני דרייברים ומונע הפעלה מחדש בכפייה. עדכוני האבטחה החודשיים ממשיכים להגיע לבד. ההגדרות המקוריות נשמרות ב-`backups\` על ה-USB, ואפשרות 6 בתפריט מחזירה אותן. כדי לכבות עדכונים אוטומטיים לגמרי, מגדירים `"mode": "ManualOnly"` בקובץ [`config/settings.json`](config/settings.json).
- **AI:** הוא רק ממליץ ולא יכול להריץ שום דבר. כל שינוי במחשב קורה רק אחרי האישור שלכם.

כל פעולה נרשמת ב-`logs\` על ה-USB. השתמשו בכלי רק במחשבים שמותר לכם לנהל.

## שאלות נפוצות

- **"Windows protected your PC":** לוחצים על *More info ← Run anyway*.
- **ה-AI איטי או לא עולה:** הפרטים נמצאים ב-`logs\llama-server.err.log`. במחשבים עם מעט זיכרון מריצים עם `-NoAI`.
- **"Some settings are managed by your organization":** ההודעה הזו נובעת ממדיניות העדכונים, ואפשרות 6 בתפריט מבטלת אותה.

## רישיון

[MIT](LICENSE). המודל gpt-oss-20b של OpenAI הוא ברישיון Apache-2.0, ו-llama.cpp ברישיון MIT.

</div>
