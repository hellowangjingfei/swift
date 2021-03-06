// RUN: %target-swift-frontend -Xllvm -new-mangling-for-tests  -parse-as-library -emit-silgen %s | %FileCheck %s
// RUN: %target-swift-frontend -Xllvm -new-mangling-for-tests -enable-astscope-lookup  -parse-as-library -emit-silgen %s | %FileCheck %s

// CHECK-LABEL: sil hidden @_T015local_recursionAAySi_Si1ytF : $@convention(thin) (Int, Int) -> () {
// CHECK:       bb0([[X:%0]] : $Int, [[Y:%1]] : $Int):
func local_recursion(_ x: Int, y: Int) {
  func self_recursive(_ a: Int) {
    self_recursive(x + a)
  }

  // Invoke local functions by passing all their captures.
  // CHECK: [[SELF_RECURSIVE_REF:%.*]] = function_ref [[SELF_RECURSIVE:@_T015local_recursionAAySi_Si1ytF14self_recursiveL_ySiF]]
  // CHECK: apply [[SELF_RECURSIVE_REF]]([[X]], [[X]])
  self_recursive(x)

  // CHECK: [[SELF_RECURSIVE_REF:%.*]] = function_ref [[SELF_RECURSIVE]]
  // CHECK: [[CLOSURE:%.*]] = partial_apply [[SELF_RECURSIVE_REF]]([[X]])
  // CHECK: [[CLOSURE_COPY:%.*]] = copy_value [[CLOSURE]]
  let sr = self_recursive
  // CHECK: apply [[CLOSURE_COPY]]([[Y]])
  sr(y)

  func mutually_recursive_1(_ a: Int) {
    mutually_recursive_2(x + a)
  }
  func mutually_recursive_2(_ b: Int) {
    mutually_recursive_1(y + b)
  }

  // CHECK: [[MUTUALLY_RECURSIVE_REF:%.*]] = function_ref [[MUTUALLY_RECURSIVE_1:@_T015local_recursionAAySi_Si1ytF20mutually_recursive_1L_ySiF]]
  // CHECK: apply [[MUTUALLY_RECURSIVE_REF]]([[X]], [[Y]], [[X]])
  mutually_recursive_1(x)

  // CHECK: [[MUTUALLY_RECURSIVE_REF:%.*]] = function_ref [[MUTUALLY_RECURSIVE_1]]
  _ = mutually_recursive_1

  func transitive_capture_1(_ a: Int) -> Int {
    return x + a
  }
  func transitive_capture_2(_ b: Int) -> Int {
    return transitive_capture_1(y + b)
  }

  // CHECK: [[TRANS_CAPTURE_REF:%.*]] = function_ref [[TRANS_CAPTURE:@_T015local_recursionAAySi_Si1ytF20transitive_capture_2L_SiSiF]]
  // CHECK: apply [[TRANS_CAPTURE_REF]]([[X]], [[X]], [[Y]])
  transitive_capture_2(x)

  // CHECK: [[TRANS_CAPTURE_REF:%.*]] = function_ref [[TRANS_CAPTURE]]
  // CHECK: [[CLOSURE:%.*]] = partial_apply [[TRANS_CAPTURE_REF]]([[X]], [[Y]])
  // CHECK: [[CLOSURE_COPY:%.*]] = copy_value [[CLOSURE]]
  let tc = transitive_capture_2
  // CHECK: apply [[CLOSURE_COPY]]([[X]])
  tc(x)

  // CHECK: [[CLOSURE_REF:%.*]] = function_ref @_T015local_recursionAAySi_Si1ytFySicfU_
  // CHECK: apply [[CLOSURE_REF]]([[X]], [[X]], [[Y]])
  let _: Void = {
    self_recursive($0)
    transitive_capture_2($0)
  }(x)

  // CHECK: [[CLOSURE_REF:%.*]] = function_ref @_T015local_recursionAAySi_Si1ytFySicfU0_
  // CHECK: [[CLOSURE:%.*]] = partial_apply [[CLOSURE_REF]]([[X]], [[Y]])
  // CHECK: [[CLOSURE_COPY:%.*]] = copy_value [[CLOSURE]]
  // CHECK: apply [[CLOSURE_COPY]]([[X]])
  let f: (Int) -> () = {
    self_recursive($0)
    transitive_capture_2($0)
  }
  f(x)
}

// CHECK: sil shared [[SELF_RECURSIVE]]
// CHECK: bb0([[A:%0]] : $Int, [[X:%1]] : $Int):
// CHECK:   [[SELF_REF:%.*]] = function_ref [[SELF_RECURSIVE]]
// CHECK:   apply [[SELF_REF]]({{.*}}, [[X]])

// CHECK: sil shared [[MUTUALLY_RECURSIVE_1]]
// CHECK: bb0([[A:%0]] : $Int, [[Y:%1]] : $Int, [[X:%2]] : $Int):
// CHECK:   [[MUTUALLY_RECURSIVE_REF:%.*]] = function_ref [[MUTUALLY_RECURSIVE_2:@_T015local_recursionAAySi_Si1ytF20mutually_recursive_2L_ySiF]]
// CHECK:   apply [[MUTUALLY_RECURSIVE_REF]]({{.*}}, [[X]], [[Y]])
// CHECK: sil shared [[MUTUALLY_RECURSIVE_2]]
// CHECK: bb0([[B:%0]] : $Int, [[X:%1]] : $Int, [[Y:%2]] : $Int):
// CHECK:   [[MUTUALLY_RECURSIVE_REF:%.*]] = function_ref [[MUTUALLY_RECURSIVE_1]]
// CHECK:   apply [[MUTUALLY_RECURSIVE_REF]]({{.*}}, [[Y]], [[X]])


// CHECK: sil shared [[TRANS_CAPTURE_1:@_T015local_recursionAAySi_Si1ytF20transitive_capture_1L_SiSiF]]
// CHECK: bb0([[A:%0]] : $Int, [[X:%1]] : $Int):

// CHECK: sil shared [[TRANS_CAPTURE]]
// CHECK: bb0([[B:%0]] : $Int, [[X:%1]] : $Int, [[Y:%2]] : $Int):
// CHECK:   [[TRANS_CAPTURE_1_REF:%.*]] = function_ref [[TRANS_CAPTURE_1]]
// CHECK:   apply [[TRANS_CAPTURE_1_REF]]({{.*}}, [[X]])

func plus<T>(_ x: T, _ y: T) -> T { return x }
func toggle<T, U>(_ x: T, _ y: U) -> U { return y }

func generic_local_recursion<T, U>(_ x: T, y: U) {
  func self_recursive(_ a: T) {
    self_recursive(plus(x, a))
  }

  self_recursive(x)
  _ = self_recursive

  func transitive_capture_1(_ a: T) -> U {
    return toggle(a, y)
  }
  func transitive_capture_2(_ b: U) -> U {
    return transitive_capture_1(toggle(b, x))
  }

  transitive_capture_2(y)
  _ = transitive_capture_2

  func no_captures() {}

  no_captures()
  _ = no_captures

  func transitive_no_captures() {
    no_captures()
  }

  transitive_no_captures()
  _ = transitive_no_captures
}

func local_properties(_ x: Int, y: Int) -> Int {
  var self_recursive: Int {
    return x + self_recursive
  }

  var transitive_capture_1: Int {
    return x
  }
  var transitive_capture_2: Int {
    return transitive_capture_1 + y
  }
  func transitive_capture_fn() -> Int {
    return transitive_capture_2
  }

  return self_recursive + transitive_capture_fn()
}

