import json, os, pathlib, resource, subprocess, sys, time, uuid
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_FSIZE, (128 * 1024 * 1024,) * 2)
if os.getppid() != 1 or b'--pmt-ui-guard-v1' not in pathlib.Path('/proc/1/cmdline').read_bytes():
    raise RuntimeError('macro controls require the private PMT guard namespace')
import uno
from com.sun.star.beans import PropertyValue
from com.sun.star.document.MacroExecMode import NEVER_EXECUTE, ALWAYS_EXECUTE_NO_WARN
from com.sun.star.document.UpdateDocMode import NO_UPDATE

def props(**values):
    return tuple((PropertyValue(Name=name, Value=value) for name, value in values.items()))
root = pathlib.Path('/pmt/output')
profile = root / 'profile'
profile.mkdir()
(profile / 'user').mkdir()
unsafe = sys.argv[2] == 'unsafe' if len(sys.argv) > 2 else False
xml = '<?xml version="1.0" encoding="UTF-8"?><oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>0</value></prop><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>false</value></prop></item><item oor:path="/org.openoffice.Office.Writer/Filter/Import/VBA"><prop oor:name="Load" oor:op="fuse"><value>true</value></prop></item></oor:items>'
(profile / 'user/registrymodifications.xcu').write_text(xml)
pipe = 'pmt-' + uuid.uuid4().hex
log = (root / 'lo.log').open('wb')
lo = subprocess.Popen(['/usr/bin/libreoffice', '-env:UserInstallation=' + profile.as_uri(), '--headless', '--nologo', '--nodefault', '--norestore', '--nolockcheck', '--accept=pipe,name=' + pipe + ';urp;StarOffice.ComponentContext'], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
local = uno.getComponentContext()
resolver = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local)
ctx = None
for attempt in range(100):
    try:
        ctx = resolver.resolve('uno:pipe,name=' + pipe + ';urp;StarOffice.ComponentContext')
        break
    except Exception:
        time.sleep(0.05)
if ctx is None:
    raise RuntimeError('UNO startup did not connect')
desktop = ctx.ServiceManager.createInstanceWithContext('com.sun.star.frame.Desktop', ctx)
source = pathlib.Path(sys.argv[1])
mode = ALWAYS_EXECUTE_NO_WARN if unsafe else NEVER_EXECUTE
load = props(MacroExecutionMode=uno.Any('short', mode), UpdateDocMode=uno.Any('short', NO_UPDATE), ReadOnly=True, Hidden='events' not in sys.argv, Silent=True, OpenNewView=True, PickListEntry=False)
doc = desktop.loadComponentFromURL(source.as_uri(), '_blank', 0, load)
if doc is None:
    raise RuntimeError('UNO returned no document')
record = {'source': source.name, 'unsafe': unsafe, 'loadProperties': {p.Name: str(p.Value) for p in load}, 'text': doc.Text.String, 'libraries': list(doc.BasicLibraries.ElementNames)}
for library in doc.BasicLibraries.ElementNames:
    try:
        doc.BasicLibraries.loadLibrary(library)
        lib = doc.BasicLibraries.getByName(library)
        record.setdefault('modules', {})[library] = {name: lib.getByName(name) for name in lib.ElementNames}
    except Exception as e:
        record.setdefault('moduleErrors', []).append(str(e))
try:
    record['events'] = {name: [(p.Name, str(p.Value)) for p in doc.Events.getByName(name)] for name in doc.Events.ElementNames if doc.Events.getByName(name)}
except Exception as e:
    record['eventsError'] = str(e)
if len(sys.argv) > 3 and sys.argv[3] == 'manual':
    script = doc.getScriptProvider().getScript('vnd.sun.star.script:Project.Module1.AutoOpen?language=Basic&location=document')
    try:
        record['manualResult'] = str(script.invoke((), (), ()))
    except Exception as e:
        record['manualError'] = str(e)
if 'makefixture' in sys.argv:
    doc.Text.String = ''
    cursor = doc.Text.createTextCursor()
    for text in ['PMT UNO DOC ä Grüße', 'First controlled list item', 'Second controlled list item', 'IMAGE-FOLLOWS']:
        cursor.gotoEnd(False)
        doc.Text.insertString(cursor, text, False)
        doc.Text.insertControlCharacter(cursor, uno.getConstantByName('com.sun.star.text.ControlCharacter.PARAGRAPH_BREAK'), False)
    paragraphs = doc.Text.createEnumeration()
    while paragraphs.hasMoreElements():
        paragraph = paragraphs.nextElement()
        if paragraph.String in ['First controlled list item', 'Second controlled list item']:
            paragraph.NumberingStyleName = 'List 1'
    cursor.gotoEnd(False)
    graphic = doc.createInstance('com.sun.star.text.TextGraphicObject')
    graphic.GraphicURL = 'file:///pmt/input/fixture.png'
    graphic.AnchorType = uno.Enum('com.sun.star.text.TextContentAnchorType', 'AS_CHARACTER')
    graphic.Width = 3200
    graphic.Height = 1600
    doc.Text.insertTextContent(cursor, graphic, False)
    doc.storeToURL((root / 'RichAutoOpen.doc').as_uri(), props(FilterName='MS Word 97', Overwrite=False))
time.sleep(0.3)
doc.storeToURL((root / 'converted.html').as_uri(), props(FilterName='HTML (StarWriter)', Overwrite=False))
doc.storeToURL((root / 'reference.txt').as_uri(), props(FilterName='Text (encoded)', FilterOptions='UTF8', Overwrite=False))
record['markers'] = [p.name for p in root.glob('*.sentinel')]
(root / 'record.json').write_text(json.dumps(record, ensure_ascii=False, indent=2))
print(json.dumps({k: record[k] for k in ['source', 'unsafe', 'libraries', 'markers']}))
doc.close(True)
desktop.terminate()
lo.wait(timeout=5)
log.close()
