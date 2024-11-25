import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:build/src/builder/build_step.dart';
import 'package:built_collection/built_collection.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:kiwi/kiwi.dart';
import 'package:kiwi_generator/src/model/kiwi_generator_error.dart';
import 'package:kiwi_generator/src/util/list_extensions.dart';
import 'package:source_gen/source_gen.dart';

const TypeChecker _registerTypeChecker = TypeChecker.fromRuntime(Register);

bool _isRegisterMethod(MethodElement method) =>
    (method.returnType is VoidType &&
        _registerTypeChecker.hasAnnotationOfExact(method));

class KiwiInjectorGenerator extends Generator {
  const KiwiInjectorGenerator();

  @override
  String? generate(LibraryReader library, BuildStep? buildStep) {
    try {
      // An injector is an abstract class where all abstract methods are
      // annotated with Register.
      final injectors = library.classes
          .where((c) =>
              c.isAbstract &&
              c.methods.where((m) => m.isAbstract).isNotEmpty &&
              c.methods
                  .where((m) => m.isAbstract && _isRegisterMethod(m))
                  .isNotEmpty)
          .toList();

      if (injectors.isEmpty) {
        return null;
      }
      final file = Library((lb) => lb
        ..body.addAll(
            injectors.map((i) => _generateInjector(i, library, buildStep))));

      final DartEmitter emitter = DartEmitter(allocator: Allocator());
      return DartFormatter().format('${file.accept(emitter)}');
    } catch (e) {
      if (e is KiwiGeneratorError || e is UnresolvedAnnotationException) {
        rethrow;
      } else if (e is Error) {
        throw KiwiGeneratorError(
            'Something went wrong with the KiwiGenerator. Please create a new ticket with a copy of your error to https://github.com/gbtb16/kiwi/issues/new',
            error: e);
      } else {
        throw KiwiGeneratorError(
            'Something went wrong with the KiwiGenerator. Please create a new ticket with a copy of your error to https://github.com/gbtb16/kiwi/issues/new');
      }
    }
  }

  Class _generateInjector(
      ClassElement injector, LibraryReader library, BuildStep? buildStep) {
    return Class((cb) => cb
      ..name = '_\$${injector.name}'
      ..extend = refer(injector.name)
      ..methods.addAll(_generateInjectorMethods(injector)));
  }

  List<Method> _generateInjectorMethods(ClassElement injector) {
    return injector.methods
        .where((m) => m.isAbstract)
        .map((m) => _generateInjectorMethod(m))
        .toList();
  }

  Method _generateInjectorMethod(MethodElement method) {
    if (method.parameters.length > 1) {
      throw KiwiGeneratorError(
          'Only 1 parameter is supported `KiwiContainer scopedContainer`, ${method.name} contains ${method.parameters.length} param(s)');
    }
    final scopedContainerParam = method.parameters.singleOrNullWhere(
      (element) =>
          element.name == 'scopedContainer' &&
          element.type.getDisplayString(withNullability: true) ==
              'KiwiContainer',
    );

    return Method.returnsVoid((mb) {
      var scopedContainer = '';
      if (scopedContainerParam != null) {
        if (scopedContainerParam.isOptional) {
          mb.optionalParameters = ListBuilder<Parameter>([
            Parameter((builder) => builder
              ..name = scopedContainerParam.name
              ..named = scopedContainerParam.isNamed
              ..required = scopedContainerParam.isRequiredNamed
              ..defaultTo = Code('null')
              ..type = Reference('KiwiContainer?'))
          ]);
        } else {
          mb.requiredParameters = ListBuilder<Parameter>([
            Parameter((builder) => builder
              ..name = scopedContainerParam.name
              ..named = scopedContainerParam.isNamed
              ..required = scopedContainerParam.isRequiredNamed
              ..defaultTo = Code('null')
              ..type = Reference('KiwiContainer?'))
          ]);
        }
        scopedContainer = '${scopedContainerParam.name} ?? ';
      } else if (method.parameters.isNotEmpty) {
        throw KiwiGeneratorError(
            'Only 1 parameter is supported `KiwiContainer scopedContainer`, ${method.name} contains ${method.parameters.length} param(s) and `KiwiContainer scopedContainer` is not included');
      }
      final registers = _generateRegisters(method);
      mb
        ..name = method.name
        ..annotations.add(refer('override'));
      if (registers == null) {
        mb..body = Block();
      } else {
        mb
          ..body = Block((bb) => bb
            ..statements.add(Code(
                'final KiwiContainer container = ${scopedContainer}KiwiContainer();'))
            ..addExpression(registers));
      }
    });
  }

  Expression? _generateRegisters(MethodElement method) {
    final annotations = _registerTypeChecker.annotationsOfExact(method);
    return annotations.isEmpty
        ? null
        : annotations.fold<Expression>(
            Reference('container'),
            (expr, annotation) => _generateRegister(
              expr,
              AnnotatedElement(ConstantReader(annotation), method),
            ),
          );
  }

  Expression _generateRegister(
      Expression registerExpression, AnnotatedElement annotatedMethod) {
    final ConstantReader annotation = annotatedMethod.annotation;
    final DartObject registerObject = annotation.objectValue;

    final String? name = registerObject.getField('name')?.toStringValue();
    final DartType? type = registerObject.getField('type')?.toTypeValue();
    final DartType? concrete = registerObject.getField('from')?.toTypeValue();
    final String? constructorName =
        registerObject.getField('constructorName')?.toStringValue();
    final DartType? concreteType = concrete ?? type;

    // TODO: Implement null type check
    if (concreteType == null) {
      throw KiwiGeneratorError(
          'null can not be registered because there is no type for null');
    }

    final String className =
        concreteType.getDisplayString(withNullability: false);
    final String typeParameters = concrete == null
        ? ''
        : '<${type?.getDisplayString(withNullability: false)}>';

    final String nameArgument = name == null ? '' : ", name: '$name'";
    final String constructorNameArgument =
        constructorName == null ? '' : '.$constructorName';

    final ClassElement? clazz =
        concreteType.element?.library?.getClass(className);
    if (clazz == null) {
      throw KiwiGeneratorError('$className not found');
    }

    final bool oneTime =
        registerObject.getField('oneTime')?.toBoolValue() ?? false;
    final Map<DartType?, String?>? resolvers =
        _computeResolvers(registerObject.getField('resolvers')?.toMapValue());

    final String methodSuffix = oneTime ? 'Singleton' : 'Factory';

    final constructor = constructorName == null
        ? clazz.unnamedConstructor
        : clazz.getNamedConstructor(constructorName);

    if (constructor == null) {
      throw KiwiGeneratorError(
          'the constructor ${clazz.name}.$constructorName does not exist');
    }

    final String factoryParameters = _generateRegisterArguments(
      constructor,
      resolvers,
    ).join(', ');

    return registerExpression.cascade(
        'register$methodSuffix$typeParameters((c) => $className$constructorNameArgument($factoryParameters)$nameArgument)');
  }

  List<String> _generateRegisterArguments(
    ConstructorElement constructor,
    Map<DartType?, String?>? resolvers,
  ) {
    return constructor.parameters
        .map((p) => _generateRegisterArgument(p, resolvers))
        .toList();
  }

  String _generateRegisterArgument(
    ParameterElement parameter,
    Map<DartType?, String?>? resolvers,
  ) {
    final List<DartType> dartTypes = resolvers == null
        ? []
        : resolvers.keys
            .where((e) =>
                e?.getDisplayString(withNullability: false) ==
                parameter.type.getDisplayString(withNullability: false))
            .where((e) => e != null)
            .map((e) => e!)
            .toList();
    final String nameArgument = dartTypes.isEmpty || resolvers == null
        ? ''
        : "'${resolvers[dartTypes.first]}'";
    return '${parameter.isNamed ? parameter.name + ': ' : ''}c.resolve<${parameter.type.getDisplayString(withNullability: false)}>($nameArgument)';
  }

  Map<DartType?, String?>? _computeResolvers(
    Map<DartObject?, DartObject?>? resolvers,
  ) {
    return resolvers?.map((key, value) => MapEntry<DartType?, String?>(
        key?.toTypeValue(), value?.toStringValue()));
  }
}
