var buckets = require('../../buckets');

var bst = new buckets.BSTree();

var x1 = symb_number(x1);
var x2 = symb_number(x2);
var x3 = symb_number(x3);

Assume(not (x1 = x2));
Assume(not (x1 = x3));
Assume(not (x2 = x3));

bst.add(x1);
bst.add(x2);
bst.add(x3);

bst.clear();
var res = bst.isEmpty();
Assert(res);
