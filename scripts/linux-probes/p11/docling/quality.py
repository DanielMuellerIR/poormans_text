import unicodedata
from html.parser import HTMLParser
from collections import Counter
def norm(text):return ' '.join(unicodedata.normalize('NFC',text).split())
class Cells(HTMLParser):
 def __init__(self):super().__init__();self.row=-1;self.col=0;self.cells=[];self.current=None;self.occupied=set()
 def handle_starttag(self,tag,attrs):
  if tag=='tr':self.row+=1;self.col=0
  if tag in ('td','th'):
   while (self.row,self.col) in self.occupied:self.col+=1
   a=dict(attrs);rs=int(a.get('rowspan',1));cs=int(a.get('colspan',1));self.current={'row':self.row,'column':self.col,'rowspan':rs,'colspan':cs,'text':''}
   for row in range(self.row,self.row+rs):
    for col in range(self.col,self.col+cs):self.occupied.add((row,col))
   self.col+=cs
 def handle_data(self,data):
  if self.current is not None:self.current['text']+=data
 def handle_endtag(self,tag):
  if tag in ('td','th') and self.current is not None:self.current['text']=norm(self.current['text']);self.cells.append(self.current);self.current=None
def measure(expected,predicted):
 expected=sorted(expected,key=lambda v:(v['row'],v['column']));predicted=sorted(predicted,key=lambda v:(v['row'],v['column']))
 pos=lambda c:(c['row'],c['column']);p={pos(c):c for c in predicted}
 cells=[]
 for e in expected:
  c=p.get(pos(e));cells.append({'expected':e,'predicted':c,'textExact':c is not None and norm(c['text'])==norm(e['text']),'spanExact':c is not None and (c['rowspan'],c['colspan'])==(e['rowspan'],e['colspan'])})
 ewords=Counter(w for c in expected for w in norm(c['text']).split());pwords=Counter(w for c in predicted for w in norm(c['text']).split())
 return {'expectedCells':len(expected),'predictedCells':len(predicted),'textExactAtCell':sum(c['textExact'] for c in cells),'spansExactAtCell':sum(c['spanExact'] for c in cells),'expectedMergedCells':sum(c['rowspan']>1 or c['colspan']>1 for c in expected),'mergedExactAtCell':sum(c['spanExact'] for c in cells if c['expected']['rowspan']>1 or c['expected']['colspan']>1),'orderedCellTextExact': [norm(c['text']) for c in expected]==[norm(c['text']) for c in predicted],'expectedWordCount':sum(ewords.values()),'missingWords':list((ewords-pwords).elements()),'extraWords':list((pwords-ewords).elements()),'cellDetails':cells}
