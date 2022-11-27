# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
require "context_data_provider"
require "context_event_handler"
require "variable_parser"
require "context_event_logger"
require "scheduled_executor_service"
require "client"
require "context"
require "context_config"

RSpec.describe ABSmartly do
  let(:client) { instance_double(Client) }

  it ".create" do
    config = ABSmartlyConfig.create
    config.client = client
    absmartly = described_class.create(config)
    expect(absmartly).not_to be_nil
  end

  it ".create throws with invalid config" do
    expect {
      config = ABSmartlyConfig.create
      ABSmartly.create(config)
    }.to raise_error(ArgumentError, "Missing Client instance configuration")
  end

  it ".create_context" do
    config = ABSmartlyConfig.create
    config.client = client

    # data_future = (CompletdawdableFuture<ContextData>) mock(
    #   CompletableFuture.class);
    # try (final MockedConstruction<DefaultContextDataProvider> dataProviderCtor = mockConstruction(
    #   DefaultContextDataProvider.class, (mock, context) -> {
    #   when(mock.getContextData()).thenReturn(dataFuture);
    # })) {
    #   final ABSmartly absmartly = ABSmartly.create(config);
    # assertEquals(1, dataProviderCtor.constructed().size());
    #
    # try (final MockedStatic<Context> contextStatic = mockStatic(Context.class)) {
    #   final Context contextMock = mock(Context.class);
    #   contextStatic.when(() -> Context.create(any(), any(), any(), any(), any(), any(), any(), any(), any()))
    #                .thenReturn(contextMock);
    #
    #   final ContextConfig contextConfig = ContextConfig.create().setUnit("user_id", "1234567");
    #   final Context context = absmartly.createContext(contextConfig);
    #   assertSame(contextMock, context);
    #
    #   final ArgumentCaptor<Clock> clockCaptor = ArgumentCaptor.forClass(Clock.class);
    #   final ArgumentCaptor<ContextConfig> configCaptor = ArgumentCaptor.forClass(ContextConfig.class);
    #   final ArgumentCaptor<ScheduledExecutorService> schedulerCaptor = ArgumentCaptor
    #                                                                      .forClass(ScheduledExecutorService.class);
    #   final ArgumentCaptor<CompletableFuture<ContextData>> dataFutureCaptor = ArgumentCaptor
    #                                                                             .forClass(CompletableFuture.class);
    #   final ArgumentCaptor<ContextDataProvider> dataProviderCaptor = ArgumentCaptor
    #                                                                    .forClass(ContextDataProvider.class);
    #   final ArgumentCaptor<ContextEventHandler> eventHandlerCaptor = ArgumentCaptor
    #                                                                    .forClass(ContextEventHandler.class);
    #   final ArgumentCaptor<ContextEventLogger> eventLoggerCaptor = ArgumentCaptor
    #                                                                  .forClass(ContextEventLogger.class);
    #   final ArgumentCaptor<VariableParser> variableParserCaptor = ArgumentCaptor
    #                                                                 .forClass(VariableParser.class);
    #   final ArgumentCaptor<AudienceMatcher> audienceMatcherCaptor = ArgumentCaptor
    #                                                                   .forClass(AudienceMatcher.class);
    #
    #   contextStatic.verify(times(1),
    #                        () -> Context.create(any(), any(), any(), any(), any(), any(), any(), any(), any()));
    #   contextStatic.verify(times(1),
    #                        () -> Context.create(clockCaptor.capture(), configCaptor.capture(), schedulerCaptor.capture(),
    #                                             dataFutureCaptor.capture(), dataProviderCaptor.capture(), eventHandlerCaptor.capture(),
    #                                             eventLoggerCaptor.capture(), variableParserCaptor.capture(),
    #                                             audienceMatcherCaptor.capture()));
    #
    #   assertEquals(Clock.systemUTC(), clockCaptor.getValue());
    #   assertSame(contextConfig, configCaptor.getValue());
    #   assertTrue(schedulerCaptor.getValue() instanceof ScheduledThreadPoolExecutor);
    #   assertSame(dataFuture, dataFutureCaptor.getValue());
    #   assertTrue(dataProviderCaptor.getValue() instanceof DefaultContextDataProvider);
    #   assertTrue(eventHandlerCaptor.getValue() instanceof DefaultContextEventHandler);
    #   assertNull(eventLoggerCaptor.getValue());
    #   assertTrue(variableParserCaptor.getValue() instanceof DefaultVariableParser);
    #   assertNotNull(audienceMatcherCaptor.getValue());
    # }
    # }
  end

  it "createContextWith" do
    # final ABSmartlyConfig config = ABSmartlyConfig.create()
    #                                               .setClient(client);
    #
    # final ContextData data = new ContextData();
    # try (final MockedConstruction<DefaultContextDataProvider> dataProviderCtor = mockConstruction(
    #   DefaultContextDataProvider.class)) {
    #   final ABSmartly absmartly = ABSmartly.create(config);
    #   assertEquals(1, dataProviderCtor.constructed().size());
    #
    #   try (final MockedStatic<Context> contextStatic = mockStatic(Context.class)) {
    #     final Context contextMock = mock(Context.class);
    #     contextStatic.when(() -> Context.create(any(), any(), any(), any(), any(), any(), any(), any(), any()))
    #                  .thenReturn(contextMock);
    #
    #     final ContextConfig contextConfig = ContextConfig.create().setUnit("user_id", "1234567");
    #     final Context context = absmartly.createContextWith(contextConfig, data);
    #     assertSame(contextMock, context);
    #
    #     verify(dataProviderCtor.constructed().get(0), times(0)).getContextData();
    #
    #     final ArgumentCaptor<Clock> clockCaptor = ArgumentCaptor.forClass(Clock.class);
    #     final ArgumentCaptor<ContextConfig> configCaptor = ArgumentCaptor.forClass(ContextConfig.class);
    #     final ArgumentCaptor<ScheduledExecutorService> schedulerCaptor = ArgumentCaptor
    #                                                                        .forClass(ScheduledExecutorService.class);
    #     final ArgumentCaptor<CompletableFuture<ContextData>> dataFutureCaptor = ArgumentCaptor
    #                                                                               .forClass(CompletableFuture.class);
    #     final ArgumentCaptor<ContextDataProvider> dataProviderCaptor = ArgumentCaptor
    #                                                                      .forClass(ContextDataProvider.class);
    #     final ArgumentCaptor<ContextEventHandler> eventHandlerCaptor = ArgumentCaptor
    #                                                                      .forClass(ContextEventHandler.class);
    #     final ArgumentCaptor<ContextEventLogger> eventLoggerCaptor = ArgumentCaptor
    #                                                                    .forClass(ContextEventLogger.class);
    #     final ArgumentCaptor<VariableParser> variableParserCaptor = ArgumentCaptor
    #                                                                   .forClass(VariableParser.class);
    #     final ArgumentCaptor<AudienceMatcher> audienceMatcherCaptor = ArgumentCaptor
    #                                                                     .forClass(AudienceMatcher.class);
    #
    #     contextStatic.verify(times(1),
    #                          () -> Context.create(any(), any(), any(), any(), any(), any(), any(), any(), any()));
    #     contextStatic.verify(times(1),
    #                          () -> Context.create(clockCaptor.capture(), configCaptor.capture(), schedulerCaptor.capture(),
    #                                               dataFutureCaptor.capture(), dataProviderCaptor.capture(), eventHandlerCaptor.capture(),
    #                                               eventLoggerCaptor.capture(), variableParserCaptor.capture(),
    #                                               audienceMatcherCaptor.capture()));
    #
    #     assertEquals(Clock.systemUTC(), clockCaptor.getValue());
    #     assertSame(contextConfig, configCaptor.getValue());
    #     assertTrue(schedulerCaptor.getValue() instanceof ScheduledThreadPoolExecutor);
    #     assertDoesNotThrow(() -> assertSame(data, dataFutureCaptor.getValue().get()));
    #     assertTrue(dataProviderCaptor.getValue() instanceof DefaultContextDataProvider);
    #     assertTrue(eventHandlerCaptor.getValue() instanceof DefaultContextEventHandler);
    #     assertNull(eventLoggerCaptor.getValue());
    #     assertTrue(variableParserCaptor.getValue() instanceof DefaultVariableParser);
    #     assertNotNull(audienceMatcherCaptor.getValue());
    #   }
    # }
  end

  it "getContextData" do
    # final CompletableFuture<ContextData> dataFuture = mock(CompletableFuture.class);
    # final ContextDataProvider dataProvider = mock(ContextDataProvider.class);
    # when(dataProvider.getContextData()).thenReturn(dataFuture);
    #
    # final ABSmartlyConfig config = ABSmartlyConfig.create()
    #                                               .setClient(client)
    #                                               .setContextDataProvider(dataProvider);
    #
    # final ABSmartly absmartly = ABSmartly.create(config);
    #
    # final CompletableFuture<ContextData> contextDataFuture = absmartly.getContextData();
    # verify(dataProvider, times(1)).getContextData();
    #
    # assertSame(dataFuture, contextDataFuture);
  end

  it "createContextWithCustomImpls" do
    # final CompletableFuture<ContextData> dataFuture = mock(CompletableFuture.class);
    # final ContextDataProvider dataProvider = mock(ContextDataProvider.class);
    # when(dataProvider.getContextData()).thenReturn(dataFuture);
    #
    # final ScheduledExecutorService scheduler = mock(ScheduledExecutorService.class);
    # final ContextEventHandler eventHandler = mock(ContextEventHandler.class);
    # final ContextEventLogger eventLogger = mock(ContextEventLogger.class);
    # final AudienceDeserializer audienceDeserializer = mock(AudienceDeserializer.class);
    # final VariableParser variableParser = mock(VariableParser.class);
    #
    # final ABSmartlyConfig config = ABSmartlyConfig.create()
    #                                               .setClient(client)
    #                                               .setContextDataProvider(dataProvider)
    #                                               .setContextEventHandler(eventHandler)
    #                                               .setContextEventLogger(eventLogger)
    #                                               .setScheduler(scheduler)
    #                                               .setAudienceDeserializer(audienceDeserializer)
    #                                               .setVariableParser(variableParser);
    #
    # final ABSmartly absmartly = ABSmartly.create(config);
    #
    # try (final MockedStatic<Context> contextStatic = mockStatic(Context.class);
    # final MockedConstruction<AudienceMatcher> audienceMatcherCtor = mockConstruction(AudienceMatcher.class,
    #                                                                                  (mock, context) -> {
    #                                                                                    assertEquals(1, context.getCount());
    # assertSame(audienceDeserializer, context.arguments().get(0));
    # })) {
    #   final Context contextMock = mock(Context.class);
    # contextStatic.when(() -> Context.create(any(), any(), any(), any(), any(), any(), any(), any(), any()))
    #              .thenReturn(contextMock);
    #
    # final ContextConfig contextConfig = ContextConfig.create().setUnit("user_id", "1234567");
    # final Context context = absmartly.createContext(contextConfig);
    # assertSame(contextMock, context);
    #
    # final ArgumentCaptor<Clock> clockCaptor = ArgumentCaptor.forClass(Clock.class);
    # final ArgumentCaptor<ContextConfig> configCaptor = ArgumentCaptor.forClass(ContextConfig.class);
    # final ArgumentCaptor<ScheduledExecutorService> schedulerCaptor = ArgumentCaptor
    #                                                                    .forClass(ScheduledExecutorService.class);
    # final ArgumentCaptor<CompletableFuture<ContextData>> dataFutureCaptor = ArgumentCaptor
    #                                                                           .forClass(CompletableFuture.class);
    # final ArgumentCaptor<ContextDataProvider> dataProviderCaptor = ArgumentCaptor
    #                                                                  .forClass(ContextDataProvider.class);
    # final ArgumentCaptor<ContextEventHandler> eventHandlerCaptor = ArgumentCaptor
    #                                                                  .forClass(ContextEventHandler.class);
    # final ArgumentCaptor<ContextEventLogger> eventLoggerCaptor = ArgumentCaptor
    #                                                                .forClass(ContextEventLogger.class);
    # final ArgumentCaptor<VariableParser> variableParserCaptor = ArgumentCaptor.forClass(VariableParser.class);
    # final ArgumentCaptor<AudienceMatcher> audienceMatcher = ArgumentCaptor.forClass(AudienceMatcher.class);
    #
    # contextStatic.verify(times(1),
    #                      () -> Context.create(any(), any(), any(), any(), any(), any(), any(), any(), any()));
    # contextStatic.verify(times(1),
    #                      () -> Context.create(clockCaptor.capture(), configCaptor.capture(), schedulerCaptor.capture(),
    #                                           dataFutureCaptor.capture(), dataProviderCaptor.capture(), eventHandlerCaptor.capture(),
    #                                           eventLoggerCaptor.capture(), variableParserCaptor.capture(), audienceMatcher.capture()));
    #
    # assertEquals(Clock.systemUTC(), clockCaptor.getValue());
    # assertSame(contextConfig, configCaptor.getValue());
    # assertSame(scheduler, schedulerCaptor.getValue());
    # assertSame(dataFuture, dataFutureCaptor.getValue());
    # assertSame(dataProvider, dataProviderCaptor.getValue());
    # assertSame(eventHandler, eventHandlerCaptor.getValue());
    # assertSame(eventLogger, eventLoggerCaptor.getValue());
    # assertSame(variableParser, variableParserCaptor.getValue());
    # assertNotNull(audienceMatcher.getValue());
    # }
  end

  it "close" do
    # final ScheduledExecutorService scheduler = mock(ScheduledExecutorService.class);
    #
    # final ABSmartlyConfig config = ABSmartlyConfig.create()
    #                                               .setClient(client)
    #                                               .setScheduler(scheduler);
    #
    # final ABSmartly absmartly = ABSmartly.create(config);
    #
    # try (final MockedStatic<Context> contextStatic = mockStatic(Context.class)) {
    #   final Context contextMock = mock(Context.class);
    #   contextStatic.when(() -> Context.create(any(), any(), any(), any(), any(), any(), any(), any(), any()))
    #                .thenReturn(contextMock);
    #
    #   final ContextConfig contextConfig = ContextConfig.create().setUnit("user_id", "1234567");
    #   final Context context = absmartly.createContext(contextConfig);
    #   assertSame(contextMock, context);
    #
    #   absmartly.close();
    #
    #   verify(scheduler, times(1)).awaitTermination(anyLong(), any());
    # }
  end
end
